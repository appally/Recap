# 端侧 ASR 选型与 iOS 落地工程指南

> 版本：v1.0 ｜ 日期：2026-07-24
> 回答：FluidAudio 对中文的价值？vs SpeechAnalyzer / 云端 API 的好处坏处？iOS 端性能/发热/体验怎么控制？
> 依据：FluidAudio 仓库源码+文档+全部 issue（v0.15.5）、Apple SpeechAnalyzer 文档、火山/讯飞协议、CoreML/thermal 能效指南

---

## 〇、一句话结论

**FluidAudio 是 2026 年 Swift 生态里中文端侧 ASR 最有希望的底座**——SenseVoice/Paraformer 的 ANE CoreML 适配是稀缺能力，中文准确率显著强于 Whisper。**但它仍是快速迭代的早期项目**：iPhone 真机数据完全缺失、中文不支持真流式（≈15s 延迟）、有一批 iOS 稳定性坑（并发崩溃、长音频丢字、iOS 27 后台 ANE 锁定）。

**最佳架构不是三选一，而是各取所长**：`SpeechAnalyzer 实时转写（省电流式）+ FluidAudio 说话人分离（系统没有）+ 云端 Seed-ASR/讯飞（高保真付费档）`。**但任何投入前，必须先在 iPhone 15/16 Pro 上做真机 POC——Mac benchmark 不能外推。**

---

## 一、FluidAudio 对中文场景的价值（核心）

### 1.1 中文准确率：开源端侧最强

| 模型 | AISHELL-1 CER | 模型大小(int8/fp16) | 峰值 RAM | RTFx(Mac M5) | 特点 |
|---|---|---|---|---|---|
| **Paraformer-large-zh** | **2.12%** | 207/411 MB | 0.24/0.38 GB | 85× | 纯中文最准，int8 无损 |
| **SenseVoice Small** | **3.09%** | 225/447 MB | 0.32/0.54 GB | 382× | 多语+**中英混读**+情感/事件标签 |
| 裸 Whisper-large（对照） | ~9–14% | — | — | — | 中文弱、繁简混、数字乱 |

**对中文会议的价值**：Paraformer/SenseVoice 解决了 Whisper 的中文老大难（错别字、繁简混、数字日期乱、中英混读强行翻译），且**非自回归一次出全部 token，比 Whisper 快 5×+**。

### 1.2 FluidAudio 的独特强项：说话人分离

- 离线 **Pyannote community-1**（AMI DER 10.6%，最准）/ 流式 **Sortformer**（≤4 人）/ **LS-EEND**（≤10 人，默认在线）三选一。
- **而 Apple SpeechAnalyzer 原生没有说话人分离**——开源项目 ambient-voice 就是"SpeechAnalyzer 转写 + FluidAudio 分离"组合。这是 FluidAudio 对会议场景不可替代的价值。

### 1.3 中文配套：ITN 逆文本归一化

[text-processing-rs](https://github.com/FluidInference/text-processing-rs)（NeMo Text Processing 的 Rust 移植，3011 测试全过）：把"两百"→"200"、"五月三号"→"5月3日"，中文会议数字/日期必备。

### 1.4 FluidAudio 的坏处（必须知道）

| 坏处 | 说明 |
|---|---|
| **中文不支持真流式** | SenseVoice/Paraformer 是非自回归批处理，FluidAudio 用 ~15s 滑窗"伪流式"，**端到端延迟 ≈15 秒**——会议记录够用，实时字幕/同传不行 |
| **iPhone 真机数据全缺** | 所有中文 CER/RTF/内存/发热都跑在 Mac M5 Pro，iPhone 不能外推 |
| **iOS 稳定性坑多** | 并发崩溃(#661)、长音频丢字(#758/#746/#803)、iOS 27 后台 ANE 锁定(#738)、Kokoro 中文 TTS 崩(#667) |
| **中文无内置热词** | CTC boosting 仅英文；会议人名/术语要自建后处理纠错 |
| **快速迭代期** | v0.15.x 几乎每周发版，API/行为可能变 |

---

## 二、三方案好处坏处对比

| 维度 | ① FluidAudio（端侧开源） | ② SpeechAnalyzer（iOS26 系统） | ③ 云端（火山 Seed-ASR/讯飞） |
|---|---|---|---|
| **中文准确率** | Paraformer 2.12% / SenseVoice 3.09%（AISHELL，Mac） | 无公开数据，社区反馈中文一般 | **真实会议最准**（论文 SOTA，需自测） |
| **流式实时** | ❌ 中文不支持（≈15s 延迟） | ✅ **原生真流式**，首字数百毫秒 | ✅ WebSocket 流式，弱网延迟大 |
| **说话人分离** | ✅ **最强项**（3 方案） | ❌ 原生无 | ⚠️ 需额外声纹服务 |
| **热词/术语** | ❌ 中文无 | ❌ 无 | ✅ **最强**（火山 boosting+correct 表） |
| **中英混读** | SenseVoice 可（chunk 边界漂移） | 系统听写尚可 | ✅ 最强 |
| **功耗发热** | ANE 可持续，但长会议发热真问题 | 🟢 **最省电**（Apple 自调优） | 🟢 端侧零 AI 算力 |
| **隐私/离线** | ✅ 完全离线 | ✅ 端侧（首次需联网下资产） | ❌ 上云 |
| **成本** | ✅ 免费 | ✅ 免费 | ⚠️ ~0.8–2 元/小时 |
| **包体积** | 最小组合 ~280MB（按需下载） | ✅ 0（系统托管） | ✅ 0 |
| **机型覆盖** | A14+（注意内存） | ❌ iOS26+Apple Intelligence(A17 Pro+/M1+) | ✅ 任意联网机型 |
| **稳定性/可控** | ✅ 可锁版本、可改 | ❌ 黑盒静默更新 | ⚠️ 依赖网络+厂商 |

### 场景路由

| 场景 | 推荐 |
|---|---|
| 隐私/免费/离线（律师医生政企学生） | ① FluidAudio |
| 高保真/付费/术语密集（记者董事会） | ③ 云端 |
| 弱网/通勤 | ① 端侧兜底，联网后台补云 |
| 旧机型（iPhone 13/14） | ① FluidAudio int8 或 ③ 云 |
| 新机型追求省电+实时 | ② SpeechAnalyzer 转写 + ① FluidAudio 分离 |
| 企业数据不出境 | ① 端侧 或 ③ 国内云 |

---

## 三、推荐架构：三方案组合（端侧为主 + 云端增强 + 弱网兜底）

```
默认层（隐私/免费/离线）
  iOS26+Apple Intelligence：SpeechAnalyzer 实时转写（省电流式）
                           + FluidAudio 说话人分离（系统没有）
  旧机型/需强可控：FluidAudio Paraformer(int8) 转写 + Silero VAD + FluidAudio 分离
增强层（付费/高保真，用户可选）
  一键"高保真"：上传录音 → 火山 Seed-ASR/讯飞 → 更准文本 + 热词纠错（人名术语）
  会后可对比端侧/云端两份结果
兜底层（弱网）
  录音永远本地留存；联网后台补传云端转写；未联网端侧即时出稿
```

**为什么不全云端**：隐私用户流失、断网不可用、长会议成本累积、合规风险。
**为什么不全端侧**：中文真实会议准确率/热词/混读弱于云端、长会议发热、旧机型不可用。
**为什么 SpeechAnalyzer + FluidAudio 组合**：前者省电流式但无分离，后者有分离但中文不流式——互补。

---

## 四、iOS 落地工程 Checklist（性能/发热/体验控制）

### 4.1 计算单元：必须 ANE 优先 🔴

```swift
let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine   // 绝不用 .all
```
- **SenseVoice 的 fp16 只在 ANE 正确，在 CPU/GPU 会 NaN 崩**（`MLModel(path)` 默认 `.all` 会踩）。
- GPU 比 ANE 快 ~8% 但**更费电、更易热节流**，iOS 上不值；Mac 上才 opt-in GPU。
- 前处理（mel/fbank/STFT）是 FP32，留 CPU（功率谱超 fp16 范围，不 ANE-compile）。
- **优先 int8**：Paraformer int8 准确率无损（2.12% 不变）、体积减半（411→207MB）、内存更低。

### 4.2 🔴 最大风险：iOS 27 限制后台 ANE 访问

Apple iOS 27 Release Notes（FluidAudio issue #738 实锤）：*"system now restricts background access to the Neural Engine"*。
- 会议 App 典型的"锁屏后台录音 + 实时端侧转写"在 iOS 27 上**可能跑不了 ANE**，只能前台转写或退回 CPU（功耗暴增）。
- **预案**：设计成"后台只录音、回前台/结束后转写"；或等 Apple FB23457001 解决。**必须在 iOS 27 真机实测**，不能假设 iOS 26 行为延续。

### 4.3 热节流阶梯降级（`ProcessInfo.thermalState`）

```swift
NotificationCenter.default.addObserver(forName: .thermalStateDidChangeNotification, ...)
```
| 状态 | 策略 |
|---|---|
| `.nominal` | 满血：大模型 + 实时转写 + 分离 |
| `.fair` | 切 int8 小模型 + 关分离 + `parallelChunkConcurrency=1` |
| `.serious` | **暂停本地转写，只录音**；UI 提示"温度高，已切录音模式，会后转写" |
| `.critical` | 停一切 AI 推理，仅保录音 |

- 结合 `isLowPowerModeEnabled`（低电量模式）一同降级。
- 转写走低 QoS（`.utility`）让系统可调度；重算任务 `.serious/.critical` 时改 `BGTaskScheduler` 延后。

### 4.4 长会议功耗控制

- **VAD 门控**（最大单项节能）：Silero VAD 剔静音，会议发言占比 40–60%，**省 40–60% 算力**。FluidAudio 默认 `maxSpeechDuration 14s`（匹配 ASR 上限）、`minSilenceDuration 0.75s`、带滞回防抖。
- **采样率 16k mono 16-bit 足够**（所有中文 ASR 都是 16k）；48kHz 立体声白耗 3–6× 算力。
- **批处理 > 实时**：会后批量可并行多 chunk（FluidAudio `parallelChunkConcurrency`，1h 文件 2.2–2.8× 加速，仅 +19–31MB）。**建议：实时用小模型出粗稿，会议结束自动大模型并发重转替换。**

### 4.5 内存管理（防 OOM）

- 三模型同载（VAD+ASR+分离）峰值 **1–1.5GB**，6GB 机型 OOM 风险高。
- **懒加载**：VAD 常驻；ASR 会议开始才加载；**说话人分离会后才加载**（实时分离最耗内存）。
- **流式读盘**：长音频用磁盘流式读（FluidAudio `streamingThreshold=480k samples≈30s`），1h 音频从"几百 MB 常驻"降到"几百 KB"（issue #256）。
- 监听 `didReceiveMemoryWarningNotification` 主动卸载非关键模型。

### 4.6 模型分发（包体积 vs 按需下载）

- **不要打包 1GB+ 进 App**（拉低下载转化、App Store 蜂窝 200MB 限制）。
- **首次按需下载**：自建 CDN/对象存储 + FluidAudio `ModelRegistry.baseURL`（国内访问稳）；或 Apple Background Asset Download。
- 离线档：内置中文 int8 小模型（~207MB）满足纯隐私/无网用户。
- v0.14.8+ 模型存 Application Support（不被系统清理）；v0.15.5+ 下载支持断点续传+校验（早期下载被代理 HTML 污染的坑已修）。
- **国内分发必须用镜像/自建 CDN**（HuggingFace 直连不稳）。

### 4.7 体验控制（实时流畅度）

- **稳定区/易变区分离渲染**：finalize 的文本不再变（不重渲染），volatile 区就地刷新（防闪烁）。SpeechAnalyzer 的 `volatileRangeChangedHandler` / FluidAudio 批处理段落天然稳定。
- **长音频 chunk seam 已知问题**（#758/#746/#803/#683）：边界掉字、粘词、多语漂移、前导静音整窗丢字。启用 `seamGapRepair`、`dualDecodeArbitration`；**真实会议必须做 seam canary 听校对测试**，短样本 WER 看不出。
- **Sortformer 流式分离有 bug**（#807 幻影帧/时间戳漂移），关键场景优先会后批分离。
- 推理全放后台线程（actor/Task），**绝不阻塞主线程**；文本渲染用 diffable 增量更新。

### 4.8 能效/审核

- `UIBackgroundModes: audio` + `AVAudioSession.setCategory(.playAndRecord)`（后台录音唯一合规通道，审核会查真实性）。
- 云端补传用 `URLSession` 后台会话，系统择机上传。

---

## 五、FluidAudio 集成必读：致命 issue 与必做验证

### 5.1 致命/阻塞性 issue

| issue | 问题 | 应对 |
|---|---|---|
| **#738** iOS 27 锁后台 ANE | 后台录音转写可能不可用 | 真机实测；预案改"后台只录音" |
| **#661** 并发 ASR+Diarizer 崩溃 | `EXC_BAD_ACCESS`（CoreML 共享 E5RT scratch 被破坏） | **会议必踩**：自己把 ASR/VAD/Diarizer 调用串到一个串行 actor |
| #528 iOS26.4 堆损坏 | 连续跑 1–5 分钟必崩 | pin ≥ v0.14.1 |
| #667/#738 Kokoro 中文 TTS 崩 | M5/macOS26.5/iOS27 | 中文 TTS 暂不上生产，等修复 |
| #758/#746/#803 长音频丢字 | 15s 边界丢 ~7s、前导静音整窗丢 | 真实会议听校对验证 |

### 5.2 集成工程要求

- **exact version pin**（如 `0.15.5`），不用 `from:`（#723 会解析错版本）。
- 开 Swift 6 strict concurrency，所有 FluidAudio manager 收敛到自己定义的 actor（#530/#425/#448）。
- 模型下载用 `ModelHub` + 自建 CDN；首次启动明确提示"下载语音模型（约 X MB）"+进度。

### 5.3 替代方案：sherpa-onnx（中文流式）

[k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 有 **Paraformer-streaming（流式！FluidAudio 没有）**，是少数能在 iPhone 做中文实时流式转写的方案。缺点：跑 ONNX Runtime/CPU（无 ANE 加速），RTF 劣于 FluidAudio。**若"实时字幕"是硬需求，考虑 sherpa-onnx 流式 + FluidAudio/云端精修。**

---

## 六、License 清单（供知情，按你的判断决定）

> 你已明确 license 不是红线、开源代码可参考迁移。以下如实列出各**模型权重**条款供法务知情（权重 license 与代码 license 不同，且涉及第三方条款）。

| 组件 | 代码 License | 权重 License | 备注 |
|---|---|---|---|
| FluidAudio SDK | Apache-2.0 | — | 无忧 |
| Silero VAD | MIT | "model-license"（事实商用广泛） | 低风险 |
| LS-EEND | 通常 MIT | NTT 自有 | 低（查 HF 卡） |
| **SenseVoice** | MIT | FunAudioLLM 自有 | 低，需法务确认条款 |
| Kokoro TTS | Apache-2.0 | Apache-2.0 | 低（但暂有崩溃） |
| **Paraformer** | MIT(FunASR) | **FunASR v1.1**（含"不得贬损"条款，未明确商用授权） | 需法务 review |
| Pyannote | MIT | MIT 但 **HF 强制 click-through**（需 token） | 低-中 |
| Sortformer | NVIDIA | **NVIDIA OML**（需登记） | 中 |
| ITN(text-processing-rs) | — | NeMo（部分 WARF 专利条款） | 中-高，建议法务 review |

**最省心组合**：Silero VAD + SenseVoice + LS-EEND + Kokoro + FluidAudio SDK（避开 Paraformer 权重/Sortformer OML/ITN 专利的不确定性）。

---

## 七、POC 验证清单（最重要——公开数据缺失，必须真机自测）

在 **iPhone 15 Pro / 16 Pro** 上跑 `SenseVoice int8 + Paraformer int8 + Silero VAD + LS-EEND`，用**真实中文会议录音**测：

- [ ] **中文 CER**（真实会议，非 AISHELL 朗读）——预期 5–10%+，定 baseline
- [ ] **RTF**（能否实时跟上；持续 30 分钟的 RTF 衰退曲线）
- [ ] **内存峰值**（三模型同载是否 OOM）
- [ ] **30 分钟持续转写热节流曲线**（thermalState 变化 + RTF 退化）
- [ ] **长音频丢字**（30+ 分钟真实会议听校对，验 #758/#746/#803）
- [ ] **并发 ASR+分离是否崩**（验 #661，串行化是否解决）
- [ ] **iOS 27 后台录音转写**是否仍可用（验 #738）
- [ ] **首模型下载时长 + 冷加载时长**（旧机型如 iPhone 13）
- [ ] **电池消耗**（30/60 分钟会议耗电 %）

---

## 八、最终决策

| 诉求 | 方案 |
|---|---|
| 中文准确率第一，可接受非实时 | FluidAudio + Paraformer int8（CER 2.12%，~207MB） |
| 中英混读 + 多语 | FluidAudio + SenseVoice int8（CER 3.09%，~225MB） |
| 会议中实时流式字幕 | sherpa-onnx + Paraformer-streaming（FluidAudio 中文不流式） |
| 省心不折腾 | Apple SpeechAnalyzer（系统框架，零包体积） |
| 中文 TTS | 暂缓（Kokoro-zh 崩溃未解决） |

**给 Recap 的推荐**：`SpeechAnalyzer 实时转写 + FluidAudio 分离` 作默认隐私档，`云端 Seed-ASR` 作高保真付费档，弱网端侧兜底。**第一步永远是 iPhone 真机 POC**——FluidAudio 值得投入，但不能盲信 Mac benchmark，iOS 稳定性/长音频/iOS 27 这些坑都得真机验证后才能放心用于生产。

---

> **一句话**：FluidAudio 把开源中文端侧 ASR 推到了"可用且强于 Whisper"的程度，加上说话人分离是会议刚需——是 Recap 音频底座的合理选择。但它是早期项目，中文不流式、iPhone 数据缺、有真实稳定性坑；**先用真实中文会议在 iPhone 上跑通 POC，再决定投入深度**。
