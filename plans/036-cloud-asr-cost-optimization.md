# Plan 036: 云端 ASR 成本优化（SpeechAnalyzer 默认 + Fun/火山推流节流）

> **Executor instructions**: Follow step by step. Run every verification
> command before the next step. On STOP conditions, stop and report — do not
> improvise. Update `plans/README.md` unless the reviewer maintains the index.
>
> **Drift check (run first)**: Workspace may have **no `.git`**. Confirm live
> code still matches excerpts below:
> - `ASRPreference.current` default `.auto`; `.auto` resolve order SA → Fun → Volc
> - `RecordingSession` feeds **every** mic chunk to `engine.feed` with no gate
> - `FunASRProtocol.runTask` parameters only `format` + `sample_rate`
> - `retranscribeFromDisk` calls `AsrEngineResolver.resolve()` (same as LIVE)
> - `VolcConfig` has no `show_utterances` / `end_window_size`
>
> On mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: L（分 Wave A→B→C；可分 PR）
- **Risk**: MED（静音门控误伤句首；断连重连影响 LIVE；计费规则以厂商为准需真机账单核对）
- **Depends on**: none 硬依赖；与 `023`（Fun 语义断句）并行时 **先合 023 的 run-task 参数扩展点**，本计划在其上加 cost 相关键，避免双改冲突
- **Category**: perf + direction（成本）
- **Planned at**: workspace snapshot 2026-07-26（无 git SHA）
- **Issue**: （未发布）

## Why this matters

产品默认路径已是 **SpeechAnalyzer（免费）**；云端 Fun-ASR / 火山仅在用户强制或 auto 回落时启用。但一旦走云端，当前实现会把 **含静音的整场 PCM 连续推流**，而厂商按 **推流音频时长** 计费——会议发言占比常仅 40–60%，静音段仍计费。

核实结论（执行前勿假设已变）：

| 事实 | 证据 |
|------|------|
| 默认 `.auto` → 优先 SA | `AsrEngineResolver.resolve` case `.auto` |
| Fun / 火山 LIVE 全量 `feed` | `RecordingSession` audioTask 无门控 |
| Fun 计费 ≈ 按秒音频（境内约 ¥0.00033/s ≈ ¥1.2/h；UI 文案写「约 ¥0.6/小时」偏乐观） | 百炼价目 + `ASRSettingsView` subtitle |
| **静音推流也计费** | 阿里云 ISI 钉群答复：「只要您一直在推流，就是计费的」；计费起点=开始推音频 |
| Fun `heartbeat=true` 仍需 **持续发静音包** 保活，默认 60s 无音频会断 | [Fun 客户端事件 / Java SDK](https://help.aliyun.com/zh/model-studio/fun-asr-client-events) |
| `usage.duration` 在 `sentence_end=true` 时返回计费秒数 | Fun 服务端事件文档 |
| 会后「重转」仍走 `resolve()`，**不会**特意上云高保真 | `MeetingSession.retranscribeFromDisk` |

本计划目标：**不伤默认 SA 路径**；云端路径可观测、可节流、会后高保真与 LIVE 解耦。

## Current state

### Resolve 默认（已正确，勿改乱序）

```96:100:RecapApp/Modules/RecapASR/AsrEngineResolver.swift
        case .auto:
            // 端侧 → Fun-ASR → 火山备
            if let engine = try? await prepare(.speechAnalyzer) { return engine }
            if let engine = try? await prepare(.funASR) { return engine }
            if let engine = try? await prepare(.volcSeedASR) { return engine }
```

### 全量推流（成本根因）

```87:98:RecapApp/Modules/RecapASR/RecordingSession.swift
            audioTask = Task { [weak self] in
                for await chunk in audioStream {
                    guard let self, !Task.isCancelled else { break }
                    do {
                        try await self.engine?.feed(chunk)
                    } catch {
                        ...
                    }
                }
            }
```

### Fun run-task 过瘦

```368:371:RecapApp/Modules/RecapASR/FunASREngine.swift
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16000,
                ],
```

### 重转与 LIVE 同引擎

```386:391:RecapApp/Modules/RecapUI/MeetingSession.swift
            let engine = try await AsrEngineResolver.resolve()
            let result = try await engine.transcribe(
                samples: samples,
                sampleRate: MeetingAudioStore.sampleRate,
                onPartial: nil
            )
```

### 产品意图（勿违背）

`产品设计方案.md` §1.1：端侧 SpeechAnalyzer 默认；云端高质量 **按需**；录音本地留存可重转。

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Unit tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:RecapASRTests CODE_SIGNING_ALLOWED=NO` | **TEST SUCCEEDED** |
| Build | 同 destination build RecapApp | **BUILD SUCCEEDED** |

（destination 以本机 `xcodebuild -showdestinations` 为准。）

## Scope

**In scope**:
- `RecapApp/Modules/RecapASR/AudioEnergyGate.swift`（新建：纯函数能量门控）
- `RecapApp/Modules/RecapASR/CloudAsrStreamPolicy.swift`（新建：云端推流策略状态机）
- `RecapApp/Modules/RecapASR/RecordingSession.swift` — 仅云端引擎启用门控
- `RecapApp/Modules/RecapASR/FunASREngine.swift` — `usage.duration` 累计；可选 `heartbeat`；run-task 参数钩子
- `RecapApp/Modules/RecapASR/VolcASREngine.swift` — 可选 `show_utterances`（质量，非本计划主路径；仅若 Wave C 需要句界）
- `RecapApp/Modules/RecapASR/AsrEngineResolver.swift` — 增加 `resolveForRetranscribe(preferCloud:)`（或等价）
- `RecapApp/Modules/RecapUI/MeetingSession.swift` — 重转入口选引擎
- `RecapApp/Modules/RecapUI/Settings/ASRSettingsView.swift` — 成本说明 + 开关文案
- `RecapApp/Modules/RecapModels/` — 若需 UserDefaults 键（`asr.cloudSilenceGate` 等）
- `RecapApp/Tests/RecapASRTests/AudioEnergyGateTests.swift`（新建）
- `RecapApp/Tests/RecapASRTests/CloudAsrStreamPolicyTests.swift`（新建）
- `plans/README.md`

**Out of scope**:
- 改 SpeechAnalyzer 喂入逻辑做本地 VAD（省电另案；本计划不碰默认免费路径热路径）
- 引入 FluidAudio / Silero CoreML（迁移计划已否决进投产）
- Fun `semantic_punctuation_enabled`（属 **023**）
- 火山二遍识别 `enable_nonstream`（更贵，禁止默认开）
- 换更便宜 8k flash 模型为默认（质量风险；仅文档备注可选）
- 服务端代理聚合计费 / RecapCloud 账单系统

## Git workflow

- 无 git：直接改工作树。
- 有 git：分支 `advisor/036-cloud-asr-cost`；按 Wave 提交。

---

## Steps

### Wave A — 可观测 + 会后路径拆分（先量后治）

#### Step A1: 累计 Fun `usage.duration`

在 `FunASREngine.handleServerText` 的 `result-generated` / `sentence_end` 分支读取：

```json
"usage": { "duration": <int seconds> }
```

- Actor 内 `billedSecondsAccumulated: Int` 累加（仅 `sentence_end == true` 且非 heartbeat）。
- `TranscribeResult` 若无字段：在 `RecapModels` 给 `TranscribeResult` 增加可选 `billedAudioSeconds: Int?`（默认 nil，SA/火山可空）。
- DEBUG / `statusText` 不强制展示；至少 `print` 或内部属性供测试读。

**Verify**: 单测构造含 `usage.duration` 的 JSON，断言累加；无 usage 时不崩。

#### Step A2: `resolveForRetranscribe`

新增 API（命名可微调，语义必须清晰）：

```swift
/// LIVE 用 resolve()；会后高保真重转：preferCloud=true 时 Fun→Volc→SA
static func resolveForRetranscribe(preferCloud: Bool = true) async throws -> any AsrEngine
```

- `MeetingSession.retranscribeFromDisk` 改用 `preferCloud: true`（用户显式「重转」= 愿付费精修；与产品「云端按需」一致）。
- LIVE `RecordingSession` **继续** `resolve()`（默认 SA）。
- Settings 可加一句：「会中默认端侧免费；点重转才优先云端」。

**Verify**: 无凭证时 `preferCloud` 回落 SA 且不抛「全失败」（或抛清晰错误，与现 `noneAvailable` 一致——二选一写清并测）。推荐：**有云凭证用云，否则 SA**。

#### Step A3: 修正 Settings 价格文案

`ASRPreference.funASR` subtitle 与 `ASRSettingsView` 改为「按推流音频时长计费 · 静音也计 · 约 ¥0.6–1.2/小时（以控制台为准）」，避免低估。

**Verify**: 文案无「无限」或「仅发言计费」误导。

---

### Wave B — 云端静音门控（核心省钱）

#### Step B1: `AudioEnergyGate` 纯函数

新建（放 `RecapASR`，无 AVFoundation 依赖优先）：

```swift
public struct AudioEnergyGate: Sendable {
    public var speechRMSThreshold: Float   // 建议默认 0.012–0.02（需单测可调）
    public var hangoverMs: Int             // 句尾保留，建议 400–800
    public var prerollMs: Int              // 句首回溯，建议 200–300
    public mutating func process(chunk: [Float], sampleRate: Double)
        -> GateDecision // .speech([Float]) | .silence
}
```

约定：
- RMS = sqrt(mean(x²))；对 chunk 判定。
- **Hangover**：从 speech→silence 后仍输出 speech 缓冲 hangoverMs，防切断尾音。
- **Preroll**：进入 speech 时，附带环形缓冲里最近 prerollMs（门控打开前缓存）。
- **仅用于 `engine.kind.isOnDevice == false`**。

**Verify**: `AudioEnergyGateTests`：全零 → silence；正弦/高幅 → speech；短静音 < hangover → 仍 speech。

#### Step B2: `CloudAsrStreamPolicy`（Fun 60s 约束）

状态机（云端专用）：

| 状态 | 行为 |
|------|------|
| `streamingSpeech` | 把 gate 输出的 speech 帧 `feed` |
| `idleSilence` | **不** `feed` 真实麦静音；累计 `silentWallMs` |
| `keepalive` | 若 `silentWallMs` 将达 **50s**（留余量）：向 Fun 发 **合成零 PCM** 100ms 包 + 要求 `heartbeat: true`；火山查文档是否有同等超时，无则允许断连后懒重连 |

Fun `run-task` 增加：

```swift
"heartbeat": true   // 仅当启用云端门控时
```

**关键假设（必须在 Step B3 真机核对）**：  
心跳静音包 **仍可能计费**。因此 keepalive 频率应 **尽量稀疏**（例如每 45–50s 一包 100ms），相对「整场 16k 连续推流」仍可省下发言间隙的大部分时长。

若真机账单证明 heartbeat 静音 **不计费**：可在 NOTES 注明，并允许更积极 keepalive。  
若证明 **与正常静音同价**：改为 Step B2′（见 STOP / 备选）：长静音 **finish-task + 关 WS**，检测到 speech 再 `run-task`（接受 0.5–2s 首字延迟）。

**Verify**: `CloudAsrStreamPolicyTests` 用虚拟时钟：49s 静音不 keepalive；50s 触发一次；speech 立刻退出 idle。

#### Step B3: 接入 `RecordingSession`

```swift
let useGate = !(resolved.kind.isOnDevice)
// AudioRecorder 仍写全量本地文件（产品硬约束）
// 仅 feed 路径经 CloudAsrStreamPolicy
```

- SA：行为与现在完全一致（全量 feed）。
- Fun/Volc：gate + policy。
- UserDefaults `asr.cloudSilenceGateEnabled` 默认 **true**（仅影响云端）；Settings 可关（调试 / 对比质量）。

**Verify**:
- 单测：mock engine 记录 `feed` 调用样本数；全零 10s 输入 → feed 样本 ≪ 10s×16k（仅 keepalive）。
- 真机（人工）：Fun BYOK，安静房间开录 2 分钟 → 控制台用量应明显低于 120s（目标：keepalive 量级，≪120）。**此条是 Wave B Done 的人工门槛**；自动化测不到账单。

---

### Wave C — 产品形态加固（可选，可另 PR）

#### Step C1: 「只录后转」提示（不做完整新 phase）

在 ASR Settings / 重转旁说明：会中 SA 免费；要云端精度请结束会议后点重转（走 A2）。不新增 MeetingPhase。

#### Step C2: 会后重转前可选「去长静音」

纯离线：对落盘 Float32 用同一 `AudioEnergyGate` 抽出 speech 段再 `transcribe`（拼接时在 segment 时间戳上加偏移表）。  
**仅** `preferCloud` 重转路径；默认关，Settings「重转时跳过长静音以省费用」。

**Verify**: 单测：中间 5s 零样本被剔除后，喂入长度减少；时间戳映射正确。

#### Step C3: 禁止默认开启火山二遍识别

确认 `VolcConfig` **无** `enable_nonstream: true`。文档注释：「二遍=更准更贵，禁止默认」。

---

## Test plan

| 文件 | 用例 |
|------|------|
| `AudioEnergyGateTests` | 静音 / 语音 / hangover / preroll |
| `CloudAsrStreamPolicyTests` | keepalive 阈值、speech 抢占、禁用门控=透传 |
| Fun JSON 解析测 | `usage.duration` 累加；heartbeat 包不计 |
| Resolver 测（若可无 Key 测顺序） | `preferCloud` 在无 Fun/Volc 时回落 SA |

模式对齐现有 `RecapASRTests/LiveTranscriptMergerTests.swift`。

## Done criteria

- [ ] SA / `.auto` 成功走 SA 时：**零**门控代码路径改变 feed 行为（表征：gate 对 on-device 短路）
- [ ] 云端 + gate 默认开：静音输入下 `feed` 字节数显著下降（单测）
- [ ] Fun 能解析并累计 `usage.duration`（单测）
- [ ] `retranscribeFromDisk` 使用 `resolveForRetranscribe(preferCloud:)`（grep 确认）
- [ ] Settings 不再暗示「云端按发言免费」
- [ ] `xcodegen` + `RecapASRTests` + App build 成功
- [ ] `plans/README.md` 本行 → DONE 或注明「账单核对待人工」
- [ ] 无 FluidAudio / 无改 023 语义断句以外的无关 Fun 参数（若 023 未合：本计划可只加 `heartbeat`，勿抢 `semantic_punctuation`）

## STOP conditions

- Fun/火山官方文档改为「仅语音活动计费」且心跳不计 → 重新评估 B2，简化为「停推即可」，勿盲目 keepalive。
- 门控导致真机句首大量丢字 → 增大 preroll/降低阈值；两次失败则默认 **关闭 gate**，保留 A 波可观测与重转拆分，报告人工。
- 断连重连方案（B2′）在无凭证沙箱无法验 → 只落地状态机单测 + 文档，不宣称省钱比例。
- 与 `023` 同时改 `runTask` 冲突 → 抽出共享 `FunASRRunTaskParams` 再改，禁止各写一份字典。

## Maintenance notes

- 会议发言占比变化会改变省钱幅度；UI 可展示「本场云端约计费 Xs（来自 usage）」。
- RecapCloud 会员代计费时，服务端应对齐同一 gate 策略，避免 BYOK 与托管行为分裂。
- Reviewer 重点：本地 PCM **必须全量落盘**；gate 只影响上行。
- Follow-up：**037** 真机账单对照表；**023** 质量断句；Silero 仅当能量门控误判率不可接受时再议。

## Advisor notes（核实摘要，供评审）

**省钱杠杆排序（默认 SA 前提下）**：

1. **保持 LIVE 在 SA**（已做）——边际成本 ≈ 0。  
2. **云端仅会后按需重转**（A2）——避免「整场实时云端」。  
3. **云端 LIVE 时静音少推 / 稀心跳**（B）——发言占比 50% 时理论上限约省一半推流秒数（扣 keepalive）。  
4. **会后重转去静音**（C2）——文件识别同样按时长，收益实在。  
5. ~~客户端「VAD 断句参数」~~——`max_sentence_silence` / `semantic_punctuation` **不省钱**，只影响切句体验（023）。  
6. ~~上 Silero~~——投入大；能量门控足够作为第一刀。

**明确无效或危险**：

- 开 `heartbeat` 却仍每 100ms 推真实静音麦数据 → **不省钱**。  
- 火山 `enable_nonstream` 二遍识别 → 更贵。  
- 对 SA 做激进门控 → 不省云费用，还可能伤端侧识别。
