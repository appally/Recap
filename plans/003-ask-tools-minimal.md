# Plan 003: Ask 工具化最小集（检索 + HITL 分发 + 来源）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Confirm `AgentInvokeSheet.askWithLLM` still
> dumps full `transcriptContext` into one user prompt with **no** tool calls,
> and chip「帮我分发待办」走同一聊天路径。 Confirm plan **001**
> `ReminderDispatcher` exists; if not, STOP — do not reimplement EventKit here.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: MED — 与 LLM provider / DeepSeek tool_choice 交互；勿重蹈 Think mode 400
- **Depends on**: `plans/001-eventkit-action-loop.md`（硬）；`plans/002-transcript-provenance-jump.md`（软：来源跳转）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

产品把「问 Recap」定义为贯穿三态的会议智能体（`界面设计方案.md` §2.6），LLM 方案要求 `AgentLoop + ToolRegistry`（`LLM层实施方案.md` §2.8）。当前实现是「整场转写塞进 prompt 的聊天窗」：chip「帮我分发待办」只会**口头答应**，回答无可靠来源。本计划交付**最小可执行工具面**：本地检索转写、HITL 真分发、回答带来源；不追求完整多步联网 Agent。

## Current state

- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 纯 `streamText`；`offlineAnswer` 对「分发」返回假成功文案
- `RecapApp/Modules/RecapLLM/LLMProvider.swift` — 仅 `streamText` + `extractViaTool`（强制单 tool）
- `RecapApp/Modules/RecapLLM/OpenAICompatibleProvider.swift` — 注释写明 DeepSeek Think mode 不支持强制 `tool_choice`
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — sheet 只传 `transcriptContext: String`，无 segments / actionItems / jump 回调
- Plan 001 交付物：`ReminderDispatcher`（必须已存在）
- Plan 002 交付物：`TranscriptAnchor` + `jumpToTranscript`（若无，来源可先展示不可跳）

### Excerpt: chat-only Ask

```353:371:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
        do {
            let provider = try LLMProviderFactory.makeCurrent()
            let system = """
            你是 Recap 会议助手。只根据用户提供的本场会议转写回答问题。
            ...
            """
            let user = """
            【本场转写】
            \(transcriptContext.isEmpty ? "（暂无转写）" : transcriptContext)
            【问题】
            \(q)
            """
            var answer = ""
            let stream = provider.streamText(
                system: system, user: user,
                model: LLMPresets.deepSeekFlash, temperature: 0.2
            )
```

### Excerpt: fake dispatch offline copy

```420:422:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
        if q.contains("待办") || q.contains("分发") {
            return "已捕捉待办：出评审方案、确认客户报价。会后可在待办区一键分发。"
        }
```

### Design constraints (inline)

From `LLM层实施方案.md` §2.8 Tool Registry（本计划只做前两项 + draft 轻量）：

| 工具 | 本计划做法 |
|------|------------|
| `search_transcript` | **本地**关键词/子串检索 segments，不经过 LLM function call |
| `create_reminder` | **不让模型静默调用**；识别分发意图 → HITL 确认表 → `ReminderDispatcher` |
| `draft_document` | 可选：写入 `AIOutput(kind: .draft)` 并在气泡下展示预览；不做邮件真发送 |
| `search_web` / `read_url` | **明确不做** |

HITL：建提醒 = 中风险 = 草稿 + 用户确认（产品方案分级表）。

Avoid：在 DeepSeek 上做强制 multi-tool `tool_choice` 循环（已知 400）。最小集 = **retrieve-then-generate + 意图分流**，代码结构预留 `AgentTool` 协议便于以后扩。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd RecapApp && xcodegen generate && xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tools exist | `rg -n "SearchTranscriptTool|DispatchRemindersIntent|AgentTool" RecapApp/Modules` | ≥1 each family |
| No fake success | `rg -n "会后可在待办区一键分发" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` | **no matches** |

## Suggested executor toolkit

- Read `plans/001-eventkit-action-loop.md` Current state for `ReminderDispatcher` API shape；若符号名不同，适配调用，勿复制第二套 EventKit。
- `swiftui-expert-skill`（若有）：改 sheet 时用。

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/AgentTools.swift` — **新建**：`AgentTool` 协议、`TranscriptHit`、`SearchTranscriptTool`（纯函数即可）
- `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` — **新建**：意图分类 + retrieve-then-generate 编排（无强制 multi tool_choice）
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 接入 runtime；分发走确认 UI；来源展示
- `RecapApp/Modules/RecapUI/DispatchConfirmSheet.swift` — **新建**：列出可分发 `ActionItem`，确认后调 `ReminderDispatcher`
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift` — 向 Ask 传入 `segments`、`actionItems` 绑定、`meetingTitle`、可选 `onJumpToTranscript`
- `plans/README.md` — 更新 003

**Out of scope**:

- `search_web` / `read_url` / 多步调研 Agent
- 发言教练
- 重写 `SkillsSheet`（可复用其 LLM 调用模式，但不合并两个入口）
- 修改 `OpenAICompatibleProvider.extractViaTool` 的 HTTP 细节（除非编译需要导出小工具）
- Prototype 工程

## Git workflow

- Branch: `advisor/003-ask-tools-minimal`
- Commit example: `feat: retrieve-then-generate Ask with HITL reminder dispatch`
- No push/PR unless asked.

## Steps

### Step 1: `SearchTranscriptTool`（本地检索）

In `RecapApp/Modules/RecapLLM/AgentTools.swift`（该模块已依赖 RecapModels）：

```swift
public struct TranscriptHit: Sendable, Hashable, Identifiable {
    public var id: String { "\(startSeconds)-\(text.hashValue)" }
    public let startSeconds: Double
    public let speakerName: String
    public let text: String
}

public enum SearchTranscriptTool {
    /// 简单检索：query 分词（空白/标点）后，段文本包含任一词即命中；按命中词数排序，最多 limit 条。
    public static func search(
        query: String,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        limit: Int = 6
    ) -> [TranscriptHit] { /* ... */ }
}
```

Speaker 名：`speakers.first { $0.id == seg.speakerId }?.name ?? "?"`。

**Verify**: `rg -n "enum SearchTranscriptTool" RecapApp/Modules/RecapLLM/AgentTools.swift` → 1。

### Step 2: 意图分流 + `AgentAskRuntime`

Create `AgentAskRuntime.swift`:

```swift
public enum AskIntent: Sendable {
    case answerQuestion
    case dispatchReminders
    case draftDocument(hint: String)
}

public enum AskIntentClassifier {
    public static func classify(_ query: String) -> AskIntent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.contains("分发") && (q.contains("待办") || q.contains("提醒")) { return .dispatchReminders }
        if q == "帮我分发待办" { return .dispatchReminders }
        if q.contains("起草") || q.contains("写一封") || q.contains("草稿") {
            return .draftDocument(hint: q)
        }
        return .answerQuestion
    }
}
```

`AgentAskRuntime.answer(...)` 流程：

1. `hits = SearchTranscriptTool.search(...)`
2. 若 hits 空且转写非空，fallback：截断转写头尾各 N 字（复用 `MinutesPipeline.cappedTranscript`）作为上下文，hits 仍可空
3. `streamText` system 强化：只根据【检索片段】回答；引用时间用 `mm:ss`；不知则说不知
4. user 只注入 hits（格式：`[mm:ss 说话人] 原文`），**不要**再塞整场原始 `transcriptContext`（长会费 token 且淹没检索）
5. 返回 `(stream, sources: hits)` 给 UI

**Verify**: `rg -n "AskIntentClassifier|AgentAskRuntime" RecapApp/Modules/RecapLLM` → ≥2。

### Step 3: `DispatchConfirmSheet`（HITL）

New SwiftUI view in RecapUI:

- Inputs: `meetingTitle: String`, `items: [ActionItem]`（过滤：`status != .dispatched` 且非低置信未确认；低置信需已 `.confirmed` 才可选）
- UI：列表多选（默认全选高置信）、主按钮「确认分发到提醒事项」
- On confirm：对选中项逐个 `await ReminderDispatcher.shared.dispatch(...)`（或 plan 001 的实际 API）；成功更新 status + `externalReminderId`；汇总「成功 N / 失败 M」
- 失败行显示错误，不标 dispatched
- **禁止**在未点确认时调用 Dispatcher

**Verify**: `rg -n "ReminderDispatcher" RecapApp/Modules/RecapUI/DispatchConfirmSheet.swift` → ≥1。

### Step 4: 改造 `AgentInvokeSheet`

1. 扩展 init 参数（建议）：

```swift
public let segments: [TranscriptSegment]
public let speakers: [Speaker]
public let meetingTitle: String
public var actionItems: [ActionItem]  // 或 () -> [ActionItem]
public var onJumpToTranscript: ((Double) -> Void)?
```

2. `ask(_:)` 开头：

```swift
switch AskIntentClassifier.classify(query) {
case .dispatchReminders:
    showDispatchConfirm = true
    // 追加一条 assistant 短消息：「请确认要分发的待办」——不要声称已经分发
    return
case .draftDocument(let hint):
    // 可选：stream 草稿 + 存 AIOutput；最小可用 = stream 预览 + 复制按钮
    break
case .answerQuestion:
    break
}
```

3. `askWithLLM` 改为使用 `AgentAskRuntime`；assistant 气泡下方列出 `sources`（`↗ mm:ss · 说话人`）；若 `onJumpToTranscript != nil` 则可点。

4. **删除** `offlineAnswer` 里「会后可在待办区一键分发」等假成功；无 Key 时对分发意图同样打开 `DispatchConfirmSheet`（Dispatcher 不依赖 LLM）。

5. PROCESS/LIVE 仍可用；LIVE 检索用当前 `segments`（由 MeetingNoteView 从 `session.blocks` 映射传入）。

**Verify**:

```bash
rg -n "会后可在待办区一键分发" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
```

→ no matches。

```bash
rg -n "AskIntentClassifier|DispatchConfirmSheet|SearchTranscriptTool" RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
```

→ ≥1 each category.

### Step 5: 接线 `MeetingNoteView`

更新 `.sheet` 里 `AgentInvokeSheet(...)`：

- `segments`: `meeting.segments`（LIVE 时优先从 `session.blocks` 映射为 `TranscriptSegment`）
- `speakers`: `meeting.speakers`
- `meetingTitle`: `meeting.title`
- `actionItems`: `meeting.actionItems`
- `onJumpToTranscript`: 若 002 已有 `jumpToTranscript` 则传入；并 `showAgent = false` 后跳转（避免 sheet 挡住）

**Verify**: `rg -n "AgentInvokeSheet\\(" RecapApp/Modules/RecapUI/MeetingNoteView.swift -A 12` → 可见新参数。

### Step 6: （可选但推荐）draft → `AIOutput`

若实现 `draftDocument` 分支：`modelContext.insert(AIOutput(kind: .draft, payloadData: text.data(using:.utf8)!, modelId:..., promptHash: "ask-draft-v1", meeting: meeting))`。  
需把 `modelContext` 传入 sheet **或**用闭包 `onSaveDraft: (String) -> Void` 由 MeetingNoteView 保存——优先闭包，避免 sheet 直接依赖 SwiftData 环境遗漏。

若时间不够：**可跳过** draft 持久化，仅 stream 预览；在 README 003 注 `DONE (draft preview only)`。

### Step 7: 构建 + 索引

`xcodegen generate` + `xcodebuild` → BUILD SUCCEEDED。  
`plans/README.md` 003 → DONE。

## Test plan

Unit（RecapModels/RecapLLM tests）:

1. `SearchTranscriptTool.search`：已知段 + query「420」命中含报价段
2. `AskIntentClassifier`：`帮我分发待办` → `.dispatchReminders`；`报价多少` → `.answerQuestion`

Manual:

1. REVIEW 问「报价多少」→ 答案下方有 ↗ 来源；点来源能跳转录（若 002 完成）
2. 点 chip「帮我分发待办」→ 确认表，**不是**「已分发」散文；确认后提醒事项可见（001）
3. 无 API Key：问答可演示降级，但分发仍走确认表 + EventKit
4. 长转写：请求不再把全文无裁剪塞进 prompt（抽查 AgentAskRuntime user 组装逻辑）

## Done criteria

- [ ] 本地 `SearchTranscriptTool` 存在且 Ask 回答路径使用其结果
- [ ] 「帮我分发待办」打开 HITL 确认并调用 `ReminderDispatcher`，无假成功文案
- [ ] Assistant 气泡展示 sources（有 hits 时）
- [ ] BUILD SUCCEEDED
- [ ] 未实现 `search_web`
- [ ] README 003 状态更新

## STOP conditions

- Plan 001 的 `ReminderDispatcher` 不存在 → STOP，先执行 001。
- 为「更像 Agent」而实现 DeepSeek 多轮强制 `tool_choice` 导致 400 → 回退到本计划的 retrieve-then-generate，勿硬刚。
- 让 LLM 在无 HITL 下直接建提醒 → 违反产品生死线，禁止。
- 修改 Scope 外的 SkillsSheet 大重构、或引入 MCP / langchain。

## Maintenance notes

- 真正的 `AgentLoop`（model-driven tool calls）应在 Foundation Models / 非 Think 端点验证后再加；保持 `AgentTool` 协议便于挂载。
- Reviewer：分发路径是否可能绕过确认；检索是否泄漏整稿进 prompt；来源是否可被模型胡编（UI 来源必须来自 hits，非模型文本解析）。
- 跨会议问答、联网调研明确后续。
