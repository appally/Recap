# Plan 041: G1 — 国行 SpeechAnalyzer 真机可用性 POC（命门）

> **性质**：单点验证。一个下午、一台国行真机，决定整个「端侧优先」战略在国行 LIVE 场景能否成立。
> **状态**：待执行（POC-gated）。本文件是执行清单，不是实现计划。
> **依据**：[[recap-app-fluidaudio-ondevice]] / [[recap-cloud-asr-byok-gap]] / 端侧ASR选型指南.md / 2026-07-30 全链路诊断

## Why this matters（命门）

「端侧优先、付费才云端」战略的最大硬约束是：**国行 iPhone 硬件级锁定 Apple Intelligence**（截至 2026-07 仍在等监管备案，硬件锁，改区/出境都不行）。

而端侧 LIVE 中文流式目前**只有一条现成路**：Apple SpeechAnalyzer。它的可用性直接决定国行用户能否「不付费、纯端侧」做实时中文转写。

**已核实的外部证据（高置信度推断，但零国行实测）**：
- WWDC25 Session 277 原话：把 SpeechAnalyzer 与 Apple Intelligence 当「可组合的两层」——前者基础转写，后者增强（通话摘要等）。
- Argmax / Forasoft / dev.to 多源佐证：基础 `SpeechTranscriber` 不提芯片要求、不门控 Apple Intelligence；compute 标注 "Neural Engine + CPU"。
- zh_CN 在 47 个 supportedLocales 内，离线包可经 `AssetInventory` 预下载。
- 历史先例：legacy `SFSpeechRecognizer` 的 on-device zh-CN 一直在国行可用。

**但**：没有任何一篇「国行 iPhone + iOS 26 实测 SpeechAnalyzer zh-CN」的报告。zh-CN 中文 CER 也是黑盒（Apple 未公布）。**这就是命门——必须真机钉死。**

## 设备 / 前置

- **国行 iPhone**（确认 Apple Intelligence 不可用：设置→Apple Intelligence 与 Siri 无开关 / 设置顶部无提示）。理想 iPhone 15 Pro+（A17 Pro，有 ANE）。
- iOS 26+（SpeechAnalyzer 最低要求）。
- 2–3 段**真实中文会议录音**（1 段近场手持、1 段远场桌面平放、1 段含人名/术语/中英混读），各 5–10 分钟 + 人工逐字稿（算 CER 用）。
- 一台**海外/港版 iPhone**（Apple Intelligence 可用）作对照组（可选但强烈建议）。

## 测试矩阵（逐项记录）

| # | 项 | 方法 | 通过线 |
|---|---|---|---|
| T1 | **可用性** | `SpeechTranscriber(.init(locale: "zh-CN"), preset: .offlineTranscription)` 是否能创建、`AssetInventory.status(.speechRecognition, locale: "zh-CN")` 是否可装/已装 | 不抛错、能转录 |
| T2 | **中文质量** | 同一音频分别过 SpeechAnalyzer（国行）vs Fun-ASR 云端，用 RecapASRBench 的 `CERScorer` 打分 | 国行 SA 的 CER 与 Fun-ASR 差距可接受（建议 ≤ +5pt）|
| T3 | **实时性** | 首字延迟、RTFx（看 `firstTokenLatencyMs` / `BenchRecord.elapsedSeconds`） | 首字 < 1s、RTFx ≥ 1（跟得上实时）|
| T4 | **发热** | 30min 连续转录，`ProcessInfo.thermalState` 曲线 | 不跃迁到 `.serious`/`.critical` 导致停转 |
| T5 | **长音频丢字** | 30min+ 录音，对比 del（删除）数 | 无明显段落丢失 |
| T6 | **国行 vs 海外对照** | 同音频同机型（国行/海外），CER 是否一致 | 一致（证明国行模型无阉割）|

> T1 是生死线：T1 不过（国行 SA 不可用）→ 后面都不用测，直接走「国行 LIVE = 云端 Fun-ASR（付费）+ 端侧兜底」分支。

## 最小执行路径（用现成 RecapASRBench，不写新代码）

RecapASRBench 已有 `SpeechAnalyzerEngine`（对照 iOS 26.5 SDK 调通）+ `CERScorer`（Levenshtein 带 S/D/I）+ `BenchMonitor`（内存/热/电量/RTFx）。

1. 国行真机连 Xcode，`xcodebuild` 跑 `RecapASRBench` 到设备。
2. 选「端侧 SpeechAnalyzer」引擎 + 真实中文音频 + 粘贴参考稿 → 开始评测。
3. 对照组：海外机同流程；或同机切 Fun-ASR 云端引擎（需 BYOK key）。
4. 记录 CER / RTFx / 峰值内存 / 热档 / 首字延迟 / 分块数，落表。

如 RecapASRBench 的 SpeechAnalyzer 在国行设备 prepare 即报 `assetUnavailable`/`isAvailable=false`，T1 即判负——这正是要确认的。

## 手工兜底片段（若想脱离 bench 快速验 T1）

```swift
import Speech
// 国行真机上跑：看是否抛错、是否出中文文本
let locale = Locale(identifier: "zh-CN")
let assetStatus = await AssetInventory.shared.status(.speechRecognition, locale: locale)
print("asset status: \(assetStatus)")   // .installed / .notInstalled / .unsupported
// 若 .notInstalled：尝试 install；若 .unsupported → 国行 SA 中文不可用（T1 负）
try await AssetInventory.shared.install(.speechRecognition, locale: locale)
let analyzer = try SpeechAnalyzer(locale: locale)
// 喂一段中文 PCM，看 results 流是否产出可读中文
```

## 决策分支（结果决定战略）

- **T1 过 + T2 质量可接受** → ✅ 端侧优先国行 LIVE 成立。维持 SpeechAnalyzer 作国行 LIVE 默认；补「国行区域探测 + zh-CN 资源 prefetch + 四态 CTA」。
- **T1 过但 T2 质量差** → 国行 LIVE 仍走 SA（兜底可用），但**会后强制 SenseVoice 重转**补质量（端侧优先战略的会后层兜底）。
- **T1 不过（国行 SA 不可用）** → ❌ 国行 LIVE 纯端侧无解。国行 LIVE 走云端 Fun-ASR（付费增值，0.288 元/h，便宜）；或等 **G2 Nemotron Multilingual 中文 POC**（CoreML/ANE，不依赖 Apple Intelligence，是国行端侧流式的唯一替代候选）。

## Acceptance

- [ ] 国行真机 T1–T6 数据落表（或 T1 即负，记录现象）
- [ ] 结论写回本文件 Status：国行 SA 可用 / 不可用 + 中文 CER
- [ ] 据结论选定国行 LIVE 路径（SA / 云端 Fun / 等 Nemotron）

## 关联

- 衍生：若 T1 负 → 启动 **G2 Nemotron Multilingual 中文 POC**（FluidAudio 0.15.5 唯一中文真流式路径，国行 ANE 可跑，质量未知）。
- 关联文档：`端侧ASR选型与iOS落地工程指南.md` §二/§五、`RecapASRBench/README.md`。
