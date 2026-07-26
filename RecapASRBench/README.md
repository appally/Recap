# RecapASRBench —— ASR 评测台 POC

把《端侧ASR选型与iOS落地工程指南》《ASR-POC搭建与测试方案》落到可跑的代码。
**不建产品，建评测台**：选一段真实中文会议音频 → 分别过 FluidAudio / SpeechAnalyzer / 火山三个引擎 → 记录 CER / RTFx / 峰值内存 / 热档 / 掉电 / 首字延迟 → 出对比表，用真机数据坐实选型。

---

## 一、文件结构

```
RecapASRBench/
├── README.md                       ← 本文件（组装指南）
├── scripts/
│   └── cer_score.py                ← 可选：Mac 上批量算 CER（App 内已内置 CERScorer）
└── RecapASRBench/
    ├── RecapASRBenchApp.swift      ← App 入口
    ├── Views/
    │   └── ContentView.swift       ← 主界面 + ViewModel + 文件选择器
    ├── Models/
    │   ├── AsrEngineKind.swift     ← 引擎枚举
    │   └── BenchRecord.swift       ← 评测记录数据模型 + ThermalLevel
    ├── Audio/
    │   └── AudioFileReader.swift   ← 读音频并重采样为 16k mono Float32
    ├── Engines/
    │   ├── AsrEngineProtocol.swift ← 统一引擎协议
    │   ├── FluidAudioEngine.swift  ← FluidAudio SenseVoice/Paraformer（端侧）
    │   ├── SpeechAnalyzerEngine.swift ← iOS26 Apple SpeechAnalyzer（端侧真流式）
    │   └── VolcASREngine.swift     ← 火山 Seed-ASR（云端 WebSocket）
    ├── Monitoring/
    │   └── BenchMonitor.swift      ← 内存/热档/电量 监控
    └── Benchmark/
        ├── CERScorer.swift         ← 字错率（Levenshtein，带 S/D/I）
        └── BenchRunner.swift       ← 单引擎评测执行器
```

---

## 二、Xcode 组装步骤（10 分钟）

### 1. 新建工程
- Xcode → File → New → Project → **iOS App**
- Product Name: `RecapASRBench`
- Interface: **SwiftUI** ｜ Language: **Swift** ｜ **勾选 Swift 6**（Use Swift 6 language mode）
- Storage: None ｜ Include Tests: 否
- Deployment Target: **iOS 26.0**（SpeechAnalyzer 需要；后台 ANE 测试用 iOS 27 beta 设备）

### 2. 删除 Xcode 自动生成的 ContentView.swift / RecapASRBenchApp.swift
（用本仓库的同名文件替换）

### 3. 把本仓库 `RecapASRBench/` 下所有 .swift 拖进工程
- 勾选 **Copy items if needed** ｜ Create groups
- 确保所有 .swift 都在 `RecapASRBench` target 的 Compile Sources 里

> ⚠️ 组装后，编辑器里那些 `Cannot find type 'AsrEngineKind' in scope` 等错误会**全部消失**——那是 SourceKit 单文件分析、看不到同 target 其他文件造成的，加入 target 后同模块类型互相可见。

### 4. 添加 FluidAudio（SPM，exact pin）
- File → Add Package Dependencies
- URL: `https://github.com/FluidInference/FluidAudio.git`
- Dependency Rule: **Exact Version `0.15.5`**（不要用 Up to Next Major，见 FluidAudio #723）
- Add to target `RecapASRBench`，勾选 library `FluidAudio`

### 5. Info.plist 配置
在 target → Info 添加：
| Key | Value |
|---|---|
| `Privacy - Microphone Usage Description` | `会议录音转写测试` |
| `Required background modes` | `App plays audio or streams audio/video/airplays` |

> 评测台读音频文件为主，麦克风/后台非必需；若要测实时录音（TC-02/05）再加。

---

## 三、各引擎集成核对清单（开箱即用的部分 vs 需手动接的部分）

骨架策略：**确定可用的 API 直接写**（FluidAudio 已对照官方源码调通；录音/CER/监控/UI 全可用）；**不确定的 API（iOS26 SpeechAnalyzer、火山帧协议）以注释占位 + 文件顶部核对清单**，保证工程整体可编译，且 BenchRunner 对每个引擎 try/catch、**某个引擎没接好不阻塞其他引擎**，再逐个接入剩余引擎。

| 引擎 | 开箱状态 | 接入动作 |
|---|---|---|
| **SpeechAnalyzer** | ✅ **已对照 iOS 26.5 SDK 调通**（`.progressiveTranscription` + `AnalyzerInput(buffer:)` + `results` 流） | 需 **Apple Intelligence 机型**（iPhone 15 Pro+）；老机型 `isAvailable=false` 会在 prepare 报错（FluidAudio 不受影响） |
| **FluidAudio** | ✅ **已对照官方源码调通**（`SenseVoiceManager` / `ParaformerManager` 的 `load` + `transcribe`） | Xcode 加 SPM 依赖 `FluidAudio` exact `0.15.5` 即可；首次运行自动从 HuggingFace 下载模型（国内建议配 hf-mirror 镜像） |
| **火山 Seed-ASR** | ✅ **已对照官方协议调通**（`bigmodel_async` + 4 Header 鉴权 + 二进制帧编解码，compression=不压缩简化） | 在 `VolcASREngine.swift` 顶部填 `appKey`/`accessKey`（控制台→大模型流式语音识别）；豆包 2.0 小时版 `volc.seedasr.sauc.duration` 已配 |

> BenchRunner 对每个引擎的 `prepare/transcribe` 都做了 try/catch，**某个引擎接入失败不会阻塞其他引擎评测**——你可以先跑通能跑的，再逐个接入。

---

## 四、准备测试音频 + 标注（决定 POC 价值）

公开 benchmark（AISHELL 朗读）不代表真实会议。至少准备：
- **2 段真实中文会议录音**（建议：1 段远场手机放桌面、1 段含人名/术语/中英混读），各 5–10 分钟即可先跑通
- 每段**人工标注逐字稿**（粘贴到界面"参考文本"框，用于算 CER）
- 格式 wav/mp3/m4a 均可（`AudioFileReader` 会重采样到 16k mono）

> 长音频（30min+）丢字验证（TC-03）再单独准备。

---

## 五、运行

1. 选 iOS 26 真机（iPhone 15 Pro / 16 Pro）→ Run
2. 点"音频"选文件 → 勾选要测的引擎 → 粘贴参考文本 → "开始评测"
3. 结果区每条显示：**CER**（绿<5% / 橙<12% / 红）、RTFx、峰值内存、热档、掉电、首字延迟、分块数
4. 想在 Mac 上批量算 CER：把各引擎输出和标注导出为 txt，`python scripts/cer_score.py --hyp 输出.txt --ref 标注.txt`

---

## 六、对应 POC 测试用例（用本评测台覆盖）

| 测试用例 | 怎么用本台测 |
|---|---|
| **TC-01** 三方案 CER 基准 | 同一音频分别过三引擎，对比 CER 列 |
| **TC-02** RTF/实时性 | 看 RTFx 列（>1 能跟上实时） |
| **TC-03** 长音频丢字 | 跑 30min+ 音频，对比 del（删除）数；App 内 CERScorer 可扩展显示 S/D/I |
| **TC-04** 内存峰值 | 看峰值内存列（FluidAudio 三模型同载需扩展本台同时加载分离） |
| **TC-05** 热节流 | 看热档列（连续 60min 多次跑，观察 fair/serious 跃迁） |
| **TC-10** 流式延迟 | 看首字延迟列（SpeechAnalyzer 真流式 vs FluidAudio 批处理 nil） |
| **TC-11** 电池 | 看掉电列 |

> TC-06（并发崩溃）、TC-07（iOS27 后台 ANE）、TC-08（分离 DER）需在引擎/监控层扩展，见各测试用例说明。

---

## 七、已知坑提醒（来自调研，落地必看）

- **FluidAudio 计算单元自动 ANE**：`precision=.int8/.fp16` 会自动 pin 到 `.cpuAndNeuralEngine`(ANE)，**无需手动配**——SenseVoice fp16 在 CPU/GPU 会 NaN，框架已替你规避（见 `SenseVoiceEncoderPrecision.computeUnits`）。
- **FluidAudio 并发崩溃 #661**：`AsrEngine` 实现已是 actor，引擎内串行；若扩展到"ASR+分离同时跑"，务必共用同一 actor，不要并发调用。
- **FluidAudio 长音频 #758/#746/#803**：本台先按 28s 分段喂入；真实长会议丢字必须人工听校对。
- **iOS 27 后台 ANE #738**：本台前台运行不受影响；后台场景需在 iOS 27 beta 单独验证。
- **内存**：当前 `AudioFileReader` 整文件读入；长音频正式版要改流式读盘（见文件内注释）。
- **火山**：二进制帧已按官方协议实现（compression 选不压缩，免 Gzip）；填凭证后即可跑。`result.text` 是累积全量（result_type=full），最终帧 `flags=0011` 判定结束。
