# Plan 023: LIVE 转写质量——标点拼装 + 会议断句 + 底稿上下文增强

> **Executor instructions**: Follow step by step. Run every verification
> command before the next step. On STOP conditions, stop and report — do not
> improvise. Update `plans/README.md` unless the reviewer maintains the index.
>
> **Drift check**: Confirm these still match live code (workspace may have no
> git — compare excerpts, not `git diff`):
> - `FunASREngine.swift` `FunASRProtocol.runTask` parameters **only**
>   `format` + `sample_rate`
> - `handleServerText` reads `sentence["text"]` only (no `words` assemble)
> - `AsrEngine.startStreaming(sampleRate:)` has no hints/context parameter
> - `MeetingBrief.entityHints` exists and is unused by ASR

## Status

- **Priority**: P0
- **Effort**: L（分 Wave A→B→C；可分 PR，但同一计划）
- **Risk**: MED（断句参数影响延迟与行长；语义断句可能略增句末延迟）
- **Depends on**: plans/017–020（DONE — merger / Fun upsert 已就绪）
- **Category**: bug + direction（质量）
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

用户在 LIVE 字幕中看不到标点、换段「乱切/太碎」，根因不是 UI 滤掉标点，而是：

1. Fun-ASR **只取 `sentence.text`**，未拼装 `words[].punctuation`（官方示例里标点常在字级字段）。
2. `run-task` **未开会议向语义断句**（`semantic_punctuation_enabled`），默认 VAD≈1300ms 静音切句，不适合会议口述。
3. **未注入底稿实体**（`MeetingBrief.entityHints` 已存在），专有名词/人名易错；产品方案明确「热词/上下文补端侧短板」。
4. 未设 `language_hints`，中英混读/远场时可能漂到错误语种（用户截图曾出现英文乱识别）。

产品意图（《产品设计方案》§1.2）：ASR 给粗稿，云端精稿，LLM 给可读稿。本计划强化 **LIVE 粗稿层**（标点可见、断句合理、词表增强），**不**在 LIVE 每句打 LLM。

## Current state（证据）

### Fun `run-task` 参数过瘦

```368:371:RecapApp/Modules/RecapASR/FunASREngine.swift
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16000,
                ],
```

阿里文档（[客户端事件](https://help.aliyun.com/zh/model-studio/fun-asr-client-events)）会议相关可选参数：

| 参数 | 文档默认 | 会议建议 |
|------|----------|----------|
| `semantic_punctuation_enabled` | false（VAD 断句） | **true**（语义断句，适合会议） |
| `max_sentence_silence` | 1300（仅 VAD 模式） | 语义模式下无效；若保留 VAD 备选可 800–2000 |
| `language_hints` | 无（自动语种） | 中文会 **`["zh"]`** |
| `vocabulary_id` | 无 | Wave C（需独立创建热词表 API） |
| `input.context` | 无 | Wave B：塞入 `entityHints`（≤400 字） |

文档说明：`punctuation_prediction_enabled` 默认 true 且不可关——服务端会出标点，但可能在 **`words[].punctuation`**，不一定已并进 `text`。

### 只读 text

```246:246:RecapApp/Modules/RecapASR/FunASREngine.swift
            let sentenceText = (sentence["text"] as? String) ?? ""
```

服务端事件示例：`text: "好，我知道了"` 且 `words[].punctuation: "，"`。若某次 `text` 无标点而 words 有，当前 UI 永远看不到。

### 底稿实体未进 ASR

- `MeetingBrief.entityHints: [String]`（`MeetingBrief.swift`）
- Ask/纪要已用 `briefPromptSummary`；**RecordingSession / FunASR 零引用**

### 火山对照（本计划不主改）

`VolcConfig` 已 `enable_punc: true` / `enable_itn: true`，但 LIVE 只发累积 partial、无句级换段（009/审计已记）。Wave C 可选「火山句边界」另开计划，勿塞进本计划主路径。

### SpeechAnalyzer

端侧无热词；019 已做 volatile/final。标点依赖系统模型。本计划 **不**改 SA preset；端侧质量靠会后重转/LLM（产品既定）。

### 约定

- 纯函数放 `RecapASR`，单测跟 `LiveTranscriptMergerTests` 同 target（`RecapASRTests`）。
- 错误处理：参数非法时引擎仍应能开流（降级到仅 format/sample_rate），勿因 hints 为空崩溃。

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Unit tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:RecapASRTests/FunASRSentenceTextTests -only-testing:RecapASRTests/LiveTranscriptMergerTests CODE_SIGNING_ALLOWED=NO` | **TEST SUCCEEDED** |
| Build | 同 destination build RecapApp | **BUILD SUCCEEDED** |

（destination id 以本机 `xcodebuild -showdestinations` 为准。）

## Scope

**In scope**:
- `RecapApp/Modules/RecapASR/FunASREngine.swift`
- 新建 `RecapApp/Modules/RecapASR/FunASRSentenceText.swift`（纯函数：拼装 text+words 标点；裁剪 context）
- `RecapApp/Modules/RecapASR/AsrEngine.swift` — 可选扩展 `startStreaming` 或增加带 options 的重载（保持旧签名默认实现）
- `RecapApp/Modules/RecapASR/RecordingSession.swift` — 传入 `AsrStreamOptions` / hints
- `RecapApp/Modules/RecapUI/MeetingSession.swift` — 从 `meeting.brief?.entityHints`（+ 可选 speakers 名）组装 hints
- `RecapApp/Tests/RecapASRTests/FunASRSentenceTextTests.swift`
- `plans/README.md`

**Out of scope**（明确不做，避免膨胀）:
- LIVE 每句 LLM 加标点 / 润色（延迟与成本；留给会后纪要）
- DashScope `vocabulary_id` 创建/更新/删除 HTTP API（Wave C 可另开 **024**）
- 火山 Seed-ASR 句级切分 / 增量 partial（另案）
- 改 SpeechAnalyzer preset 或强制端侧出中文标点
- UI 大改（换段动画、手动调 VAD 滑条——可选设置可留 TODO）
- 改 MinutesPipeline prompt

## Git workflow

- 仓库若无 git：直接改工作树，由用户自行提交。
- 若有 git：分支 `advisor/023-live-asr-quality`；commit 按 Wave 拆分。

---

## Steps

### Wave A — 标点拼装 + 会议断句参数（P0，无网络依赖可单测）

#### Step A1: 纯函数 `FunASRSentenceText`

新建文件，至少：

```swift
public enum FunASRSentenceText {
    /// 优先用服务端 text；若几乎无标点而 words 含 punctuation，则 word.text+punctuation 拼接。
    public static func compose(sentenceText: String, words: [[String: Any]]?) -> String

    /// 将 entity hints 压成 context 用的单行（空白分隔），总长 ≤ maxChars（默认 380，留余量）。
    public static func contextLine(from hints: [String], maxChars: Int = 380) -> String
}
```

规则（写进测试）:
1. `text` 已含 `，。？！、；：` 任一时 → 直接返回 trim(text)。
2. 否则若 `words` 非空 → 按序拼接 `word["text"]` + `word["punctuation"]`（缺省 `""`）。
3. words 空 → 返回 trim(text)。
4. `contextLine`：去空、去重保序、用空格拼接，超长从尾截断不拆半词（尽量在空格处截）。

**Verify**: `FunASRSentenceTextTests` 覆盖上述 1–4 → 全绿。

#### Step A2: `handleServerText` 使用 compose

在 `result-generated` 分支：

```swift
let words = sentence["words"] as? [[String: Any]]
let sentenceText = FunASRSentenceText.compose(
    sentenceText: (sentence["text"] as? String) ?? "",
    words: words
)
```

其后 partial/segment 逻辑不变（仍走 020 的 upsert / heartbeat）。

**Verify**: BUILD；既有 `LiveTranscriptMergerTests` 仍绿。

#### Step A3: 会议向 `run-task` 参数

扩展 `FunASRProtocol.runTask`：

```swift
static func runTask(
    taskId: String,
    languageHint: String? = "zh",
    semanticPunctuation: Bool = true,
    contextHints: [String] = []
) -> [String: Any]
```

`parameters` 增加：
- `semantic_punctuation_enabled`: `semanticPunctuation`（会议默认 **true**）
- `language_hints`: `languageHint.map { [$0] }`（有值才写入）
- 勿传无效的 `max_sentence_silence` 当语义断句为 true（文档：仅 VAD 模式生效）

`input`：若 `contextHints` 非空，构造：

```json
"input": {
  "context": [{
    "role": "user",
    "content": [{ "type": "input_text", "text": "<contextLine>" }]
  }]
}
```

空 hints 时保持 `"input": {}`。

`startStreaming` 需能接收 options（见 Wave B）；Wave A 可先让引擎内部默认 `semanticPunctuation=true, languageHint="zh"`，即使尚未接线 brief。

**Verify**: 真机或抓包（可选）：run-task JSON 含 `semantic_punctuation_enabled: true`。至少单元测试构造 `runTask` 字典并断言键值（把 `runTask` 保持 `internal`/`package` 可测，或测试 compose + 用 `@testable`）。

---

### Wave B — 底稿 entityHints → Fun context（P0）

#### Step B1: 流式选项类型

在 `RecapASR`：

```swift
public struct AsrStreamOptions: Sendable, Equatable {
    public var languageHint: String?       // "zh"
    public var semanticPunctuation: Bool   // Fun：会议 true
    public var lexiconHints: [String]      // 人名/产品名
    public static let meetingDefault = AsrStreamOptions(
        languageHint: "zh",
        semanticPunctuation: true,
        lexiconHints: []
    )
}
```

`AsrEngine` 增加默认扩展，避免打破所有引擎：

```swift
func startStreaming(sampleRate: Double, options: AsrStreamOptions) async throws -> AsyncStream<AsrStreamEvent>
```

默认实现：忽略 options，调用现有 `startStreaming(sampleRate:)`。  
`FunASREngine` **覆盖**并使用 options。  
`SpeechAnalyzerEngine` / `VolcASREngine`：可忽略（或 Volc 仅将来用 lexicon——本计划不改 Volc 请求体）。

#### Step B2: RecordingSession

`start(sampleRate:audioFileURL:options:)`（默认 `.meetingDefault`），把 options 传给 `startStreaming`。

#### Step B3: MeetingSession 组装 lexicon

开录前：

```swift
var hints = meeting.brief?.entityHints ?? []
hints.append(contentsOf: meeting.speakers.map(\.name).filter { !$0.isEmpty && $0 != "转写" })
// 可选：从 title 拆词——勿过度；entityHints 优先
options.lexiconHints = Array(Set(hints)).prefix(40) // 或保序去重
```

`resumeLive` / `startLive` 同样传入（底稿中途更新：可选在下次 resume 刷新；本计划不要求热更新 continue-task）。

**Verify**: BUILD；无 brief 时 options.lexiconHints 空仍可开录。有 brief 时（DEBUG 日志可选）确认 contextLine 非空——勿打 API Key。

---

### Wave C — 验收清单 + 文档锚点（P1，轻量）

#### Step C1: 设置文案（可选一行）

`ASRSettingsView` Fun 说明追加一句：「会议默认语义断句；标点来自云端句/字级结果。」勿做复杂 UI。

#### Step C2: README / 真机验收

`RecapApp/真机验收清单.md` 或 `RecapApp/README.md` 增加 3 条：
1. 中文连续讲话 → LIVE 定稿行可见 `，。`
2. 停顿短于 ~0.5s 的从句 → 不宜切成过碎多行（语义断句）
3. 底稿含生僻产品名 → 识别优于无底稿（主观，AB 即可）

#### Step C3: 登记 follow-up（只写计划索引，不实现）

在 `plans/README.md` Batch H 笔记中登记：
- **024**（可选）：DashScope `vocabulary_id` 持久热词表
- **025**（可选）：火山句级 segment + 增量
- LIVE LLM 标点：拒绝（与产品「会中不打断」冲突）

**Verify**: 文档存在对应条目；本计划代码范围无 024/025 实现。

---

## Test plan

| 用例 | 文件 |
|------|------|
| text 已有标点 → 不二次拼接 | `FunASRSentenceTextTests` |
| text 无标点 + words 有 punctuation → 拼出「好，我知道了」 | 同上 |
| words 缺 punctuation 键 → 仍可读 | 同上 |
| contextLine 截断 ≤380 且不崩 | 同上 |
| merger 回归 7 例 | `LiveTranscriptMergerTests` |

手工（Fun Key）：开录念「你好，我知道了。预算提到百分之三十。」→ 定稿行含标点；对比改前。

## Done criteria

- [ ] `FunASRSentenceText.compose` 存在且单测通过
- [ ] Fun `handleServerText` 使用 compose
- [ ] `run-task` 默认 `semantic_punctuation_enabled: true`，可选 `language_hints: ["zh"]`
- [ ] 有 `entityHints` 时 `input.context` 带 `input_text`（≤400 字约束）
- [ ] `AsrStreamOptions` 接线 MeetingSession → RecordingSession → FunASR
- [ ] SA/Volc 旧路径仍能编译运行（忽略 options）
- [ ] `xcodebuild test` 指定 ASRTests 全绿；App BUILD SUCCEEDED
- [ ] `plans/README.md` 本行 DONE；024/025 仅笔记不实现

## STOP conditions

- 阿里改字段名导致 `words` 结构全空且 compose 无法测通 → 保留 text 直通，标点步骤降级，报告字段样例。
- `semantic_punctuation_enabled: true` 导致首句延迟不可接受（>2s 体感）→ 改为默认 false + `max_sentence_silence: 1600`，并在 NOTES 写明，勿擅自上 LLM。
- `startStreaming` 签名改动迫使大面积无关模块重写 → 改用 Fun 专用 `setOptions` 在 `prepare` 后、开流前设置，缩小 diff。
- `vocabulary_id` 或 WorkspaceId 被误加进本计划实现 → STOP，挪到 024。

## Maintenance notes

- Reviewer 重点：context 是否可能泄漏敏感底稿到阿里（产品已接受云端 ASR；确认仅 hints 短列表）。
- 改 Fun 模型名（`ASRPresets.funRealtimeModel`）时核对 `language_hints` / context 是否仍支持。
- 语义断句与 UI「当前行波形」：句更长时 `showLiveMeter` 仍挂 last row，预期正确。
- 未来 024：`vocabulary_id` 与 `context` 可并存（阿里文档：热词表 + 上下文增强）。

## Findings considered and rejected（本计划内）

| 想法 | 结论 |
|------|------|
| LIVE 流式 LLM 补标点 | 拒：延迟/成本/违背「会中余光」 |
| 客户端用正则乱加句号 | 拒：准确率差，污染证据句 |
| 强制所有引擎统一句长 | 拒：SA/Volc 语义不同；只把 Fun 会议参数做对 |
| 本计划实装 vocabulary HTTP | 拒：需 Workspace/配额/生命周期；另开 024 |
