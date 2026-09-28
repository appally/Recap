# Plan 055: LIVE 声纹抽检——在场 chips + 「听起来像 TA」轻提示（POC-gated）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（Step 1「魔法可见」核心：把 047 的会后声纹能力提前到 LIVE 可见——"名字说一次，从此跟人走"的第一现场）
- **Effort**: M（新 actor + 音频流 tap + LIVE UI；全部复用既有模型与门）
- **Risk**: MEDIUM-HIGH（音频流耦合 / 后台模型驻留策略 / 真机发热）——**Release 默认关，FeatureFlag 门控，POC 过门槛再拍板默认值**
- **Depends on**: 047（画廊/IdentityMatcher，已完成）；053 无关；054 软（`speakerSummary` 字段预留，可后接）
- **Category**: feature (experimental, flag-gated)

## Why this matters

声纹归名目前只发生在会后 diarization（用户要等整理完、且大多不会主动长按看）。LIVE 中每 ~15-30 秒对当前语音做一次 CAM++ 抽检、命中本机画廊，就能在**会中**亮出「在场：王总 · 还有未识别的声音」并轻提示"听起来像王总"——这是《定位升级与产品重构建议-2026-09》里性价比最高的差异化可视化：**模型、画廊、推理门、同意书全部现成，缺的只是把推理从"会后批"挪一个实例到"会中抽检"**。

## Current state（勘察结论，2026-09-16 核实）

- **嵌入引擎现成**：`CampPlusEmbedderProvider`（`Diarization/Identity/SpeakerEmbeddingProvider.swift`）——actor 单例，`ensureLoaded()` / `embed(samples: [Float])` / `unload()`；CAM++ 随包 15.8MB（`campplus-coreml` folder reference），熔断退避内置；推理走 `CoreMLInferenceGate`（`CoreMLInferenceGate.swift:17`，actor，与 SenseVoice/diarizer 串行互斥）。
- **匹配引擎现成**：`IdentityMatcher`（actor，`match<S: RandomAccessCollection & Sendable>` :95，配置 `IdentityMatchConfig`）；画廊 `VoiceprintGallery`（schema v2）；同意模型 `VoiceprintConsent`（`Diarization/VoiceprintConsent.swift`）。
- **音频流形态**：`AudioRecorder.start(targetSampleRate: 16000)` 返回 `AsyncStream<[Float]>`（AudioRecorder.swift:84）——16k mono 样本流，MeetingSession/RecordingSession 消费后喂引擎。**tap 点与单/多消费者语义是本计划第一勘察点（Wave A.0）**。
- **VAD 现成**：`EnergyVAD.swift` 纯 CPU 能量+过零率，已从 LIVE 转写路径退役、注释明言保留复用——正好用于"抽检窗口里有没有够多有效语音"的门控（只影响抽检时机，不碰 ASR）。
- **已知冲突点**：`CampPlusEmbedderProvider.unload()` 的文档写明调用时机含"切后台 / idle"——若该策略对 LIVE 生效，后台录音时 spotter 会陷入反复重载。**Wave A.1 必须先查清 unload 调用点并与 LIVE 驻留需求协调**。
- **LIVE UI**：字幕主舞台在 MeetingNoteView（LIVE 态段落）；MeetingSession 已有多个 @Published 驱动该界面。

## Implementation

### Wave A: 勘察 + 地基（无 UI）

0. **音频 tap 勘察**：读 `RecordingSession.swift` + `PCMConsumeBuffer.swift`，确认 16k 样本流是单消费者还是可广播。要求：spotter 以**只读旁路**消费（append 进环形缓冲），任何情况下不得对 ASR 输入路径产生反压/延迟。若 AsyncStream 单消费者不可直接旁路，在消费循环里同步 append 环形缓冲（O(1)），推理全部丢给独立 Task——**append 必须在音频回调线程上无锁或极轻**。
1. **模型驻留协调**：找出 `unload()` 的全部调用点；约定"LIVE 且 spotter 启用期间不 unload"（或退避重载），写进代码注释；与内存告警路径（`RecapAppApp.swift:63-75`）保持兼容（告警仍可强制 unload，spotter 下次 embed 前 `ensureLoaded` 自然恢复）。
2. **新建 `LiveVoiceprintSpotter` actor**（`Diarization/Identity/LiveVoiceprintSpotter.swift`）：
   - 输入：`func ingest(_ samples: [Float])`（环形缓冲，容量 ~16s@16k）。
   - 触发纪律：距上次推理 ≥15s **且** 窗口内 EnergyVAD 判定净语音 ≥3s 才触发；推理经 `CoreMLInferenceGate`；触发前查 `ThermalGate`（MeetingSession.swift 顶部既有），thermal serious+ 时跳过本次。
   - 匹配：`CampPlusEmbedderProvider.shared.embed` → `IdentityMatcher.match`（调用姿势以 `DiarizationService.diarizeMeeting` 既有用法为准，勿自创配置）；**无声纹画廊或 `VoiceprintConsent` 未授权 → spotter 整体惰性关闭（不加载模型、不推理、零日志噪音）**。
   - 输出：`AsyncStream<SpotEvent>` 或回调——`matched(entry)` / `noMatch` / `skipped`。
   - 可测性：嵌入与匹配都走协议注入（`SpeakerEmbeddingProvider` 协议已存在；为 matcher 抽最小协议）。
3. **FeatureFlags**：新增 `liveVoiceprintSpotter`（DEBUG 默认开，Release 默认关），与既有 flag 风格一致（FeatureFlags.swift）。

### Wave B: LIVE UI（MeetingSession + MeetingNoteView）

1. MeetingSession 持有 spotter，startLive 启动 / endLive 停止并 `unload`；新增 `@Published var livePresence: LivePresenceState`（`named: [String]`、`hasUnknownVoice: Bool`、`pendingPrompt: NamedEntry?`）。
2. 在场 chips（LIVE 字幕舞台上沿）：`在场：王总 · 还有未识别的声音`。**诚实口径：未识别不做人数推断（现场聚类不可靠），只说"还有未识别的声音"**；首个命中落地前整行不渲染（避免空态噪音）。
3. 「听起来像 TA」轻提示：每个画廊条目每场最多一次——"听起来像「王总」[是][不是]"。**是** → 本场 chips 内该声音显示为该名（会话级映射）；**不是** → 本场不再询问，记负样本日志（供后续阈值校准，08 报告 §9.5 飞轮口径）。**不改转写说话人标注、不写画廊**——命名仍走 047 会后流程（v1 边界，红线）。
4. 054 软集成：命中变化时更新 Live Activity `speakerSummary`（054 已预留字段；054 未合则跳过）。
5. a11y：chips 合并朗读；轻提示走站内既有横幅/Toast 语义与 Haptics 管理。

**红线**：不碰 ASR 输入流（只读、无反压）；不改转写说话人归属；无同意/无画廊完全静默；推理串行门+热门控+停机 unload 三道闸一个不能少；Release 默认关。

### Wave C: 真机 POC（拍板依据，不达门槛则 flag 保持关闭并归档数据）

30 分钟、2-3 名已注册声纹的真实会议：① 开口到 chip 命中 ≤30s；② 误命中 0 次（未注册者不被归名）；③ 录音/转写与热状态无感知劣化（对照关闭 flag 的同场景）；④ 电量曲线无异常。产出数据归档 `plans/bench-results/`，作为 Release 默认值的拍板依据。

## Verification

1. `xcodegen generate && sh scripts/fix_scheme.sh`；构建 + 全量回归（README「How to execute」）。
2. 新增单测：spotter 触发状态机（窗口/净语音/最小间隔三条件、thermal 跳过、无画廊惰性关闭、匹配结果→状态映射），fake embedder/matcher 注入。
3. DEBUG 手测（模拟器）：flag 开 + 无画廊 → 零变化；注册一个声纹（`VoiceSampleRecorderSheet`）→ 真机或模拟器播放该人音频进麦 → chips 出现、轻提示可确认/否决。
4. Wave C POC 数据齐全后才讨论 Release 默认值；未过门槛 → flag 保持关、计划状态记 PARTIAL，不阻塞 053/054。

## STOP conditions

- Wave A.0 发现样本流无法无反压旁路（消费循环结构性耦合）——停下来给出观察与备选（如 recorder 层加广播），勿在引擎路径上"先凑合"。
- Wave A.1 发现 unload 策略冲突无法在不破坏既有内存纪律的前提下协调——停下来报告两边的调用图。
- 真机 POC 出现 ASR 质量回归或 thermal warning——立即停，数据归档，flag 回退关闭。
