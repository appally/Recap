# Recap ASR POC 搭建与测试方案

> 版本：v1.0 ｜ 日期：2026-07-24
> 目标：用最小工程 + 真实中文会议音频，坐实"FluidAudio / SpeechAnalyzer / 云端"在 iPhone 上的真实表现，回答选型与组合问题
> 关联：《端侧ASR选型与iOS落地工程指南.md》

---

## 〇、POC 要回答的问题（所有公开数据缺失的项）

调研留下来的不确定性，全部用真机数据收敛：

1. FluidAudio（SenseVoice/Paraformer）在 **iPhone** 上的中文 CER（Mac 是 2.12%/3.09%，iPhone 未知）
2. 三方案在**真实中文会议**（远场/口语/多人/中英混读/含术语）的 CER 对比
3. FluidAudio 的 **RTF / 能否实时跟上** + 持续 30 分钟的衰退曲线
4. **长音频丢字**（issue #758/#746/#803）在真实会议是否复现、多严重
5. **并发 ASR+分离崩溃**（#661）串行化后是否解决
6. **iOS 27 后台 ANE 锁定**（#738）对"后台录音转写"的实际影响
7. **内存峰值 / OOM**（三模型同载）
8. **热节流曲线** + **电池消耗**
9. **说话人分离**（FluidAudio）在中文会议的质量
10. **流式延迟**（SpeechAnalyzer 真流式 vs FluidAudio 伪流式 ≈15s vs sherpa-onnx 流式）

POC 不做产品功能，只做**评测台**：导入音频 → 过三个引擎 → 记录指标 → 出对比表。

---

## 一、验收标准（POC 完成的标志）

产出一张 **三方案真机对比表**（CER / RTF / 内存峰值 / 30min 热节流 / 电池 / 长音频丢字率 / 流式延迟 / 分离 DER），并据此给出选型决策。具体判据见每个测试用例的"通过线"。

---

## 二、环境准备

### 2.1 硬件
| 设备 | 用途 |
|---|---|
| **iPhone 15 Pro / 16 Pro**（Apple Intelligence，8GB+） | 主测机（SpeechAnalyzer + FluidAudio 全跑） |
| **iPhone 13 或 14**（A15/A16，6GB） | 旧机型/内存压力/冷启动测试 |
| 任一 iPhone 装 **iOS 27 beta** | 后台 ANE 锁定验证（#738） |

### 2.2 软件
- Xcode 26 + Swift 6（strict concurrency）
- iOS 26（主）+ iOS 27 beta（后台测试）
- FluidAudio **exact pin `0.15.5`**（不用 `from:`）

### 2.3 账号 / Key
- **火山引擎**：开通语音技术，拿 ASR AppID + Token（Seed-ASR 流式）—— 主云端
- 阿里百炼 / 讯飞（备选云端，交叉验证）
- **HuggingFace**：下载 SenseVoice/Paraformer CoreML 模型（Pyannote 需 token 接受条款）

### 2.4 测试语料（最关键，决定 POC 价值）

**自建 5–10 小时真实中文会议录音**，覆盖：
| 类别 | 时长 | 说明 |
|---|---|---|
| 朗读对照 | 0.5h | AISHELL 测试集片段，验证"Mac→iPhone 是否一致" |
| 干净近场会议 | 1h | 手机贴近、安静、2–3 人 |
| **远场会议** | 2h | 手机放桌面、会议室、多人（真实痛点） |
| 中英混读 | 1h | "飞书 OKR Transformer" 类 |
| 含专有名词/术语 | 1h | 公司名/人名/行业术语（测热词短板） |
| 长会议 | 1h+ 单条 | 测长音频丢字、热节流、内存 |

**每条音频必须人工标注逐字稿**（用于算 CER）。标注是 POC 最耗时的部分，但不可省——没有 ground truth 就没有 CER。

---

## 三、工程搭建步骤

POC 工程 = 一个 SwiftUI App **"RecapASRBench"**：选音频文件 → 选引擎 → 跑 → 记录指标 → 导出报告。

### 步骤 1：创建工程
```
Xcode → New → App → RecapASRBench
Interface: SwiftUI, Language: Swift, Swift 6
Deployment: iOS 26.0（后台测试用 iOS 27 beta 设备）
Info.plist:
  NSMicrophoneUsageDescription = "会议录音转写测试"
  UIBackgroundModes = ["audio"]
```

### 步骤 2：集成 FluidAudio（SPM exact pin）
```
File → Add Package Dependencies
URL: https://github.com/FluidInference/FluidAudio.git
Exact Version: 0.15.5    # 不要用 from:，会解析错版本（issue #723）
Add Product: FluidAudio
```
模型下载策略：先 HF 直连测；国内不稳就设 `ModelHub.offlineMode` 或 `ModelRegistry.baseURL` 指自建镜像/hf-mirror。

### 步骤 3：录音 / 音频读取（16k mono）
```swift
import AVFoundation

// 录音配置（实时测试用）
let session = AVAudioApplication.shared
try session.setCategory(.playAndRecord, mode: .voiceChat)  // 激活系统 AEC/降噪
try session.setPreferredSampleRate(16000)                  // 16k 足够，别 48k

// 文件读取（评测台主用：流式读盘，防 OOM #256）
let engine = AVAudioEngine()
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                           sampleRate: 16000, channels: 1, interleaved: false)!
let file = try AVAudioFile(forReading: url)
// 用 chunk 读取（每次 ~30s），不要一次性 file.pcmBuffer 全加载
```

### 步骤 4：FluidAudio 引擎封装（ANE pin + 串行 actor）
```swift
import FluidAudio

// 🔴 关键：所有 FluidAudio manager 收敛到一个串行 actor（防 #661 并发崩溃）
actor AsrBenchEngine {
    private var senseVoice: AsrManager?
    private var paraformer: AsrManager?
    private var vad: VadManager?
    private var diarizer: SpeakerDiarizationManager?  // 会后才加载

    func loadSenseVoice() async throws {
        // SPM 模型默认走 ANE；若手动配 MLModelConfiguration 必须 .cpuAndNeuralEngine
        // 🔴 绝不用 .all —— SenseVoice fp16 在 CPU/GPU 会 NaN（SenseVoice.md）
        let model = try await AsrModels.downloadAndLoad(version: .senseVoice)
        senseVoice = AsrManager(model: model, config: .default)
    }

    func transcribe(samples: [Float]) async throws -> String {
        // 串行调用，ASR 与 Diarizer 绝不并发（#661）
        return try await senseVoice?.transcribe(samples: samples) ?? ""
    }
}
```
> API 签名以 FluidAudio 官方文档为准（`AsrModels.downloadAndLoad` / `AsrManager.transcribe(samples:)`），此处为骨架示意，集成时核对 `Documentation/ASR/SenseVoice.md`、`Paraformer.md`。

### 步骤 5：SpeechAnalyzer 引擎（iOS 26，真流式对照）
```swift
import Speech

@available(iOS 26, *)
func transcribeWithSpeechAnalyzer(samples: AsyncStream<[Float]>) async throws -> String {
    let locale = Locale(identifier: "zh-CN")
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveLiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    var finalized = ""
    for try await result in transcriber.results {
        if result.isFinal { finalized += result.text }      // 定稿
        // result.text（volatile）= 实时粗稿，用于测首字延迟
    }
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return finalized
}
```

### 步骤 6：云端引擎（火山 Seed-ASR WebSocket 流式）
```swift
// 用 URLSession WebSocket Task 连火山流式 ASR
// 按 docs.volcengine.com/docs/6561/80818 协议：16k mono zh-CN，每包 ~100ms 音频
// 可带 boosting_table_name（热词）测热词效果
// 记录：首字延迟、端到端延迟、网络 RTT
```

### 步骤 7：监控埋点（thermal / 内存 / RTF / 电量）
```swift
import UIKit

// 热节流（B.2）
NotificationCenter.default.addObserver(
    forName: .thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
    let s = ProcessInfo.processInfo.thermalState  // .nominal/.fair/.serious/.critical
    BenchLogger.log(.thermal(s))
}

// 内存（footprint）
let footprint = task_info // 用 mach_task_basic_info.resident_size 记录峰值

// 低电量模式
NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, ...)

// RTF：记录 每段音频时长 / 转写耗时 → RTFx
// 电量：记录 测试前后 UIDevice.current.batteryLevel（需 UIDevice.current.isBatteryMonitoringEnabled = true）
```
用一个 `BenchLogger` 把所有指标落 CSV，便于汇总。

### 步骤 8：CER 评测脚本（Python，跑在 Mac）
```python
# 用 jiwer 算字错率（中文按字切分）
from jiwer import cer
def score(hyp: str, ref: str) -> float:
    return cer(reference=list(ref), hypothesis=list(hyp))  # 按字
# 批量：每条音频的引擎输出 vs 人工标注 → 汇总每引擎的平均 CER
```

---

## 四、测试用例（逐个）

> 每个用例：目的 / 步骤 / 记录指标 / 通过线（判据）。所有用例在 **iPhone 15/16 Pro + iOS 26** 跑，特殊标注的另加设备。

### TC-01 三方案中文 CER 基准对比（核心）
- **目的**：拿 FluidAudio(SenseVoice/Paraformer) vs SpeechAnalyzer vs 云端 在各类语料的 CER
- **步骤**：每条测试音频分别过 4 个引擎（SenseVoice int8 / Paraformer int8 / SpeechAnalyzer / 火山），输出文本 vs 人工标注算 CER
- **记录**：每引擎×每语料类别的 CER 表
- **通过线**：FluidAudio 真实会议 CER ≤ 12%（端侧可用门槛）；云端作为天花板参照

### TC-02 RTF / 实时性
- **目的**：FluidAudio 能否实时跟上说话；持续衰退曲线
- **步骤**：跑 30 分钟连续音频，每 5 分钟记一段 RTFx
- **记录**：RTFx 随时间衰退曲线（预期首 5min ~10× → 后期 ~3–5×）
- **通过线**：全程 RTFx ≥ 1（能跟上实时）；理想 ≥ 3

### TC-03 长音频丢字（#758/#746/#803）
- **目的**：验证 chunk 边界是否丢字（会议必踩）
- **步骤**：跑 30+/60 分钟真实会议，输出 vs 标注，**逐段人工听校对**找丢字位置；重点看 15s chunk 边界、前导静音段
- **记录**：丢字率（丢失字数/总字数）、丢字位置分布
- **通过线**：丢字率 < 1%；> 3% 必须启用 `seamGapRepair`/分段策略重测

### TC-04 内存峰值与 OOM（#256）
- **目的**：单模型 vs 三模型同载的内存峰值；旧机型是否 OOM
- **步骤**：分别测 ①仅 ASR ②ASR+VAD ③ASR+VAD+分离 三档峰值；在 iPhone 13(6GB) 跑
- **记录**：各档 resident_size 峰值；是否触发 memory warning / jetsam 杀进程
- **通过线**：三模型同载 < 1.5GB 且 6GB 机型不 OOM；否则必须懒加载+会后分离

### TC-05 热节流曲线（30/60 min）
- **目的**：持续转写触发热节流的时机与 RTF 退化
- **步骤**：前台持续转写 60 分钟，秒级记录 `thermalState` + RTFx + 机身温度体感
- **记录**：thermalState 跃迁时间点（nominal→fair→serious）、对应 RTF 退化
- **通过线**：能实现"fair 切 int8 / serious 只录音"的阶梯降级且不崩

### TC-06 并发 ASR+分离崩溃（#661）
- **目的**：验证并发跑 ASR+Diarizer 是否 `EXC_BAD_ACCESS`，串行化后是否解决
- **步骤**：① 并发调用 ASR + 分离（预期崩） ② 收敛到单 actor 串行（预期稳）
- **记录**：是否崩溃、崩溃栈
- **通过线**：串行化方案连续跑 30 分钟不崩

### TC-07 iOS 27 后台 ANE 锁定（#738，最大风险）
- **目的**：iOS 27 上"后台录音 + 实时端侧转写"是否仍可用
- **步骤**：iOS 27 beta 设备，开始录音转写 → 锁屏/切后台 → 观察转写是否继续、是否报错、是否退 CPU
- **记录**：后台时 ANE 是否可用、转写是否中断、CPU 占用/功耗变化
- **通过线**：明确结论——后台可用 / 需改"后台只录音前台转写" / 完全不可用。**此项结果直接决定产品形态**

### TC-08 说话人分离质量（FluidAudio）
- **目的**：中文会议分离准确率
- **步骤**：用已知说话人数的会议音频，跑 LS-EEND / Pyannote community-1，输出说话人标签 vs 人工标注算 DER
- **记录**：DER（错分率）、限人数（LS-EEND≤10/Sortformer≤4）
- **通过线**：DER ≤ 20%（学术水平可用）；2–3 人小会期望更好

### TC-09 热词 / 术语 / 人名（端侧短板验证）
- **目的**：端侧无热词对人名术语的误识别率；云端热词的增益
- **步骤**：用含专有名词语料，对比 ①FluidAudio 裸跑 ②FluidAudio + LLM 后处理纠错（注入实体表）③云端带热词
- **记录**：专有名词正确率三档对比
- **通过线**：端侧+LLM纠错 专有名词正确率 ≥ 云端的 80%

### TC-10 流式延迟对比
- **目的**：实时字幕可行性
- **步骤**：测首字延迟 + 端到端延迟：SpeechAnalyzer（真流式）/ FluidAudio（伪流式≈15s）/ sherpa-onnx Paraformer-streaming（流式但CPU）
- **记录**：三者延迟
- **通过线**：明确"实时字幕用谁"——若 SpeechAnalyzer 首字 <1s 则实时字幕用 SpeechAnalyzer，FluidAudio 仅会后精修/分离

### TC-11 电池消耗
- **目的**：会议场景可接受的续航
- **步骤**：满电开始，前台持续录音+转写 30/60 分钟，记耗电 %
- **记录**：30min 耗电%、60min 耗电%
- **通过线**：30min < 10%（参照 SpeechAnalyzer 实测 <5%）

### TC-12 模型下载与冷启动
- **目的**：首次体验
- **步骤**：首次下载 SenseVoice int8 + Silero + LS-EEND，记下载时长/体积；冷启动模型加载时长（iPhone 13 vs 16 Pro）
- **记录**：下载体积、时长、冷加载秒数
- **通过线**：冷加载 < 3s（新机）；旧机型可接受长一些

---

## 五、数据记录表模板（每个测试填一行）

| 测试 | 引擎 | 语料 | CER | RTFx | 内存峰值 | thermal峰值 | 耗电 | 丢字率 | 延迟 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|

---

## 六、决策矩阵（数据 → 选型）

把 TC 结果填入，按规则决策：

| 结果 | 决策 |
|---|---|
| FluidAudio 真实会议 CER ≤ 12% 且 RTFx≥1 且 TC-03 丢字率<1% | ✅ 端侧 FluidAudio 可作默认档 |
| SpeechAnalyzer 中文 CER 接近 FluidAudio 且首字<1s | 实时字幕走 SpeechAnalyzer，FluidAudio 仅做分离+会后精修 |
| TC-07 iOS27 后台不可用 | 产品形态定为"后台只录音，回前台/会后转写" |
| TC-06 串行化解决崩溃 | 集成时所有 manager 收敛单 actor |
| TC-09 端侧+LLM纠错 ≥ 云端80% | "实体表+LLM纠错"补救方案成立 |
| 云端 CER 显著优于端侧（>3pp） | 高保真付费档上云为刚需 |
| TC-11 30min 耗电 >15% | 默认改为"只录音会后转写"或强降级 |

**最终架构定调**（基于数据）：
- 默认隐私档：`SpeechAnalyzer 实时转写 + FluidAudio 分离`（若 TC-07/10 支持）或 `FluidAudio 会后转写+分离`（若后台/流式不行）
- 高保真档：云端 Seed-ASR（若 TC-01 证明显著更准）
- 兜底：录音本地留存，弱网端侧出稿

---

## 七、POC 执行计划（约 8 个工作日）

| 天 | 任务 |
|---|---|
| D1 | 环境/账号/模型下载；创建工程；集成 FluidAudio SPM |
| D2 | 录音+文件读取；FluidAudio SenseVoice/Paraformer 跑通；SpeechAnalyzer 跑通；云端 WebSocket 跑通 |
| D3 | 监控埋点（thermal/内存/RTF/电量）+ CER 脚本；测试语料标注 |
| D4 | TC-01 三方案 CER 基准（核心数据） |
| D5 | TC-02/03/04（RTF/长音频丢字/内存） |
| D6 | TC-05/06/08（热节流/并发崩/分离） |
| D7 | TC-07（iOS27 后台，需 beta 设备）+ TC-09/10/11/12 |
| D8 | 数据汇总；填决策矩阵；出选型结论 |

---

## 八、风险与降级

- **FluidAudio API 变动**：v0.15.x 快速迭代，集成时以官方 `Documentation/` 为准，骨架代码需按实际签名调整。
- **iOS 27 beta 不稳**：TC-07 若设备/系统不可用，标记"待 GA 后复测"，不阻塞其他结论。
- **测试语料标注成本**：若来不及标 10h，至少标 2h（远场+含术语各 1h），保证 TC-01/03/09 有 ground truth。
- **模型下载受限**：国内 HF 不稳，提前配 hf-mirror 或自建 CDN。

---

> **POC 的唯一使命**：把"FluidAudio 中文行不行、iOS 发热崩不崩、后台能不能转、要不要上云"这四个问题，用 iPhone 真机 + 真实会议的数据一次性坐实。数据出来前，任何架构决策都是空中楼阁；数据出来后，选型就是填表。
