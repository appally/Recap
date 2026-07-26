# Plan 002: 待办/问答溯源跳转录

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Confirm these still hold in live code:
> (1) `TodoListPayload.Item` has `evidence_quote` but **no** `start_seconds`;
> (2) `MeetingNoteView.persistTodos` does not set `startSeconds`;
> (3) `ActionItemCard.sourcePill` is a non-tappable `Text("↗ …")`.
> If already fully implemented, mark DONE and stop.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: LOW–MED — Schema 变更影响 LLM tool JSON；ScrollViewReader 锚点需稳定 id
- **Depends on**: none（建议在 001 之后改 `ActionItemCard`，减少合并冲突）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

界面方案要求每条待办带来源回链（↗ 时间戳可跳原句），这是信任基建。模型已有 `evidenceQuote` / `startSeconds`，但 LLM schema 不产时间戳、持久化不写、UI 不跳转——用户无法核验 AI。本计划打通：**提取时写入时间锚点 → 卡面可点 → 摘要切到逐字稿并滚到原句**。

## Current state

- `RecapApp/Modules/RecapLLM/Schemas.swift` — `TodoListPayload.Item` 字段到 `evidence_quote` 为止
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — `persistTodos` 未传 `startSeconds`；`summaryTab` 0=摘要/1=逐字稿；`transcriptBody` 用 `SpeakerBlockView`
- `RecapApp/Modules/RecapUI/Components.swift` — `sourcePill` 仅展示
- `RecapApp/Modules/RecapModels/ActionItem.swift` — `startSeconds: Double?` 已存在
- `RecapApp/Modules/RecapUI/TranscriptBlock.swift` — block `id` 可来自 `segment.id.uuidString`
- `界面设计方案.md` §2.5 / §2.7 — 「来源胶囊(朱砂时间戳)」+ 双向锚点（本计划做 **待办→逐字稿**；逐字稿→摘要反向可留 stub）

### Excerpt: schema without start_seconds

```7:14:RecapApp/Modules/RecapLLM/Schemas.swift
    public struct Item: Codable, Sendable {
        public let task: String
        public let owner: String?
        public let owner_source: String?
        public let due: String?
        public let priority: String?
        public let confidence: Double
        public let evidence_quote: String?
```

### Excerpt: persistTodos omits startSeconds

```474:488:RecapApp/Modules/RecapUI/MeetingNoteView.swift
    private func persistTodos(_ items: [TodoListPayload.Item]) {
        for item in items {
            let due = item.due.flatMap { ISO8601DateFormatter().date(from: $0) }
            modelContext.insert(ActionItem(
                task: item.task,
                // ...
                evidenceQuote: item.evidence_quote,
                status: .draft,
                meeting: meeting
            ))
```

### Excerpt: non-interactive source pill

```211:217:RecapApp/Modules/RecapUI/Components.swift
    private var sourcePill: some View {
        Text("↗ \(item.sourceTime)")
            .font(.recapTimestamp)
            .foregroundStyle(Color.recapCinnabar)
            // ...
    }
```

### Design constraints

- 来源必须可核验；`evidence_quote` 禁止改写（已在 todoSystem prompt）。
- 跳转：切到「逐字稿」tab + `ScrollViewReader.scrollTo` 对应 block。
- 拿不到时间戳时 pill 可禁用或显示 `--:--`，**不要**编造秒数。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regen | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Schema field | `rg -n "start_seconds" RecapApp/Modules/RecapLLM/Schemas.swift` | ≥1 |
| Jump API | `rg -n "scrollToTranscript|onJumpToTranscript" RecapApp/Modules/RecapUI` | ≥1 |

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/Schemas.swift` — 可选 `start_seconds: Double?`
- `RecapApp/Modules/RecapLLM/MinutesPipeline.swift` — `todoSystem` 提示模型在能定位时填 `start_seconds`（秒，相对会议开始）
- `RecapApp/Modules/RecapModels/TranscriptAnchor.swift` — **新建**纯函数：用 `evidence_quote` 在 segments 里定位 `startSeconds`
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — persist 写入锚点；摘要/逐字稿共用 Scroll 锚点；接收 jump
- `RecapApp/Modules/RecapUI/Components.swift` — `sourcePill` 可点；可选展示 `evidenceQuote` 一行茶灰
- `RecapApp/Modules/RecapUI/TranscriptBlock.swift` — 仅当需要稳定 `id` 与 segment 对齐时微调
- `plans/README.md` — 更新 002 状态

**Out of scope**:

- 逐字稿 → 摘要反向锚点（「↗ 跳摘要」）
- 音频 seek/播放
- 说话人 diarization
- EventKit（001）
- Ask AgentLoop（003）——但 jump 回调应足够稳定供 003 复用

## Git workflow

- 分支建议：`advisor/002-transcript-provenance-jump`
- Commit example: `feat: jump from action-item source pill to transcript`
- No push/PR unless asked.

## Steps

### Step 1: `TranscriptAnchor` 纯定位

Create `RecapApp/Modules/RecapModels/TranscriptAnchor.swift`:

```swift
public enum TranscriptAnchor {
    /// 用证据原文在分段中定位 startSeconds；失败返回 nil（禁止编造）。
    public static func startSeconds(
        evidenceQuote: String?,
        in segments: [TranscriptSegment]
    ) -> Double? {
        guard let raw = evidenceQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // 1) 精确包含
        if let hit = segments.first(where: { $0.text.contains(raw) }) {
            return hit.startSeconds
        }
        // 2) 去空白后再比
        let compact = raw.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        if compact.count >= 6,
           let hit = segments.first(where: {
               $0.text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                   .contains(compact)
           }) {
            return hit.startSeconds
        }
        // 3) 较长公共子串：取 quote 前 12 字滑动匹配（实现保持简单）
        let needle = String(raw.prefix(12))
        if needle.count >= 6,
           let hit = segments.first(where: { $0.text.contains(needle) }) {
            return hit.startSeconds
        }
        return nil
    }

    public static func blockId(forStartSeconds start: Double, segments: [TranscriptSegment]) -> String? {
        segments.first(where: { abs($0.startSeconds - start) < 0.05 })?.id.uuidString
            ?? segments.first(where: { $0.startSeconds == start })?.id.uuidString
    }
}
```

**Verify**: `rg -n "enum TranscriptAnchor" RecapApp/Modules/RecapModels/TranscriptAnchor.swift` → 1。

### Step 2: Schema 增加可选 `start_seconds`

In `Schemas.swift` `Item`:

- 添加 `public let start_seconds: Double?`
- 更新 `init`
- 在 `JSONSchema` properties 增加 `start_seconds`：`type: ["number","null"]`，description：`证据句在转写中的开始秒数；无法定位则为 null`
- 加入 `required` 数组（与其它可空字段一致：字段名 required，值可为 null）

Update demo todos in `MeetingSession.startMockReveal` 补 `start_seconds: nil` 或具体秒数，保证编译。

**Verify**: `rg -n "start_seconds" RecapApp/Modules/RecapLLM/Schemas.swift RecapApp/Modules/RecapUI/MeetingSession.swift` → 多处；build 在后续步骤。

### Step 3: Prompt 与 persist

1. `MinutesPipeline.todoSystem` 追加一条：若能从转写时间线判断证据句位置，填 `start_seconds`（数字秒）；否则 null，禁止猜测。
2. `MeetingNoteView.persistTodos`：

```swift
let anchored = item.start_seconds
    ?? TranscriptAnchor.startSeconds(evidenceQuote: item.evidence_quote, in: meeting.segments)
// ActionItem(..., startSeconds: anchored, ...)
```

**Verify**:

```bash
rg -n "TranscriptAnchor.startSeconds|start_seconds" RecapApp/Modules/RecapUI/MeetingNoteView.swift
```

→ ≥1。

### Step 4: MeetingNoteView 跳转基础设施

1. 给 `reviewContent` 的 `ScrollView` 包上 `ScrollViewReader`（或拆出独立 reader）。
2. 为逐字稿每个 `SpeakerBlockView` 设置 `.id(block.id)`（LIVE 已有；REVIEW `transcriptBody` 必须有）。
3. 新增方法：

```swift
private func jumpToTranscript(startSeconds: Double) {
    summaryTab = 1
    let blocks = /* same as transcriptBody */
    let id = TranscriptAnchor.blockId(forStartSeconds: startSeconds, segments: meeting.segments)
        ?? blocks.min(by: { abs(parse($0.timestamp) - startSeconds) < abs(parse($1.timestamp) - startSeconds) })?.id
    guard let id else { return }
    // 短暂 delay 等 tab 切换完成再 scroll
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        withAnimation(.recapSoft) { proxy.scrollTo(id, anchor: .center) }
    }
}
```

把 `proxy` 经闭包或 `@State` 持有；实现以能编译、能滚为准。

4. `ActionItemCard` 增加 `onJumpToSource: ((Double) -> Void)?`；仅当 `item.startSeconds != nil` 时 pill 可点。

**Verify**: `rg -n "onJumpToSource|jumpToTranscript" RecapApp/Modules/RecapUI` → ≥2。

### Step 5: 卡面展示证据一句（可选但建议）

在 `ActionItemCard` title 下，若 `evidenceQuote` 非空，显示一行 `.recapMeta` 茶灰、最多 2 行：`「\(quote)」`。增强可核验性，不另开页面。

**Verify**: `rg -n "evidenceQuote" RecapApp/Modules/RecapUI/Components.swift` → ≥1。

### Step 6: 构建

同 001 的 `xcodegen generate` + `xcodebuild … BUILD SUCCEEDED`。

### Step 7: 更新 `plans/README.md` 002 → DONE

## Test plan

Unit-test `TranscriptAnchor`（可挂在 001 建的 `RecapModelsTests`，或本计划新建同一 test target）：

1. 精确子串命中 → 返回对应 `startSeconds`
2. 空白差异仍命中
3. 无匹配 → `nil`（不返回 0 除非真是 0 秒段）

Manual：

1. 打开种子会议或跑完一场带 API Key 的会 → 待办 pill 非 `--:--`
2. 点 ↗ → 切到逐字稿且目标句在视口中部
3. 无 `startSeconds` 的项：pill 不可点或无跳转，不崩溃

## Done criteria

- [ ] Schema 含 `start_seconds`；`persistTodos` 写入 `ActionItem.startSeconds`（模型值或 Anchor 回退）
- [ ] `sourcePill` 可点击并触发 tab 切换 + scroll
- [ ] `TranscriptAnchor` 无匹配返回 nil
- [ ] BUILD SUCCEEDED
- [ ] Scope 外未改
- [ ] README 002 状态更新

## STOP conditions

- LLM 因 schema 变更持续 400：检查 `required` / `additionalProperties` 与 DeepSeek tool 约束；可临时让 `start_seconds` 不进 required 仅作 properties——若需此回退，在 PR/报告中写明。
- REVIEW 摘要与逐字稿不能共享同一 `ScrollViewReader` 导致滚动无效：允许为 `transcriptBody` 单独包 Reader，但 jump 必须先 `summaryTab = 1`。
- 为「跳转」引入音频播放依赖 → 超出范围，STOP。

## Maintenance notes

- Plan 003 的 Ask 来源列表应调用同一 `jumpToTranscript`（通过回调注入 `AgentInvokeSheet` 或通知 MeetingNoteView）。
- Reviewer：关注假时间戳（Anchor 是否在无匹配时仍给值）。
- 反向锚点（稿→摘要）与播放 seek 是明确后续。
