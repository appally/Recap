# Plan 035: Ask 对话气泡渲染受限 Markdown（助手侧）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: This workspace may have **no `.git`**. Compare
> the "Current state" excerpts below against live files. Proceed only if
> `AgentInvokeSheet.messageRow` still uses `Text(message.text)` for both roles,
> and `AgentSystemPrompt.ask` still says「像同事口头答复」with **no** Markdown
> formatting guidance. On mismatch, STOP.

## Status

- **State**: DONE（2026-07-25）— Build + RecapUITests/RecapLLMTests 全绿；真机冒烟留给人工
- **Priority**: P1
- **Effort**: M
- **Risk**: MED — 流式每 token 重解析可能卡顿；系统 Markdown 能力有限，过度依赖第三方会膨胀依赖面
- **Depends on**: none（UI 层独立；与 Batch I 的 030/031 无硬依赖）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）
- **Issue**: （未发布）

## Why this matters

「问 Recap」助手气泡用 `Text(String)` **按字面渲染**。模型常输出 `**加粗**`、列表 `-`、行内 `` `code` ``、链接；用户看到原始符号，阅读成本高。产品文档（`产品设计方案.md`）已设想「50ms 防抖后 Markdown 重渲染」，但从未落地。本计划只解决 **Ask 助手气泡** 的受限 Markdown 显示与流式性能，不改持久化 schema、不引入完整 GFM 引擎。

## Current state

### Architecture (unchanged by this plan’s data path)

```
MeetingNoteView.sheet → AgentInvokeSheet（渲染）
                         └─ AskConversationModel.messages: [AskBubble]
                               └─ text: String（流式 .textDelta 累加）
                               └─ SwiftData ChatMessageRecord.text（仍存源 Markdown/纯文本）
```

### Excerpt: 纯文本气泡（根因）

```298:324:RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
    private func messageRow(_ message: AskBubble) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    // ...
            }
        case .assistant:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if message.text.isEmpty, message.isStreaming {
                    TypingDots()
                } else {
                    Text(message.text)
                        .font(.system(size: 15, weight: .regular, design: .default))
                        .lineSpacing(4)
                        .foregroundStyle(Color.recapInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

**SwiftUI 陷阱（必须理解）**：`Text("**hi**")`（`LocalizedStringKey`）会解析 Markdown；`Text(someStringVariable)`（`String`）等价于字面文本，**不会**解析。因此「看起来像没支持 Markdown」是类型分派结果，不是系统能力缺失。

### Excerpt: 流式每 delta 立刻刷新 UI

```643:651:RecapApp/Modules/RecapUI/AskConversationModel.swift
            case .textDelta(let t):
                answer += t
                updateAssistant(
                    id: assistantId,
                    text: answer,
                    streaming: true,
                    steps: chips(from: pendingSteps),
                    citations: citations
                )
```

### Excerpt: system prompt 偏向口语纯文本

```15:21:RecapApp/Modules/RecapLLM/Agent/AgentSystemPrompt.swift
        return """
        你是 Recap 会议助手。...
        用简体中文，简洁，像同事口头答复。涉及转写事实时用 mm:ss 标时间。不要开场白。
```

### Excerpt: 消息模型是 String（保持不变）

```33:43:RecapApp/Modules/RecapUI/AskConversationModel.swift
public struct AskBubble: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public var text: String
    // ...
```

### Related but NOT chat rendering

| 组件 | 用途 | 本计划关系 |
|------|------|------------|
| `MinutesMarkdownParser` | 纪要 Markdown → `MeetingSummary` | **禁止**复用为气泡渲染器 |
| `MeetingNoteView.shareMarkdown` | 分享导出字符串 | 不改 |
| `SearchWebTool.parseSearchMarkdown` | 解析工具结果 | 不改 |
| `产品设计方案.md` ~248 | 「50ms 防抖 Markdown 重渲染」愿景 | 本计划落实到 Ask 气泡 |

### Dependencies today

`RecapApp/project.yml` packages: OpenAI + ArgmaxOSS only。无 MarkdownUI / PicoMarkdownView / cmark。

### Design tokens to reuse

From `RecapApp/Modules/RecapUI/DesignSystem.swift`:

- Ink: `Color.recapInk`；次要：`Color.recapTea`；品牌：`Color.recapCeladon`
- 正文尺度：助手气泡现为 15pt regular + `lineSpacing(4)` — 保持
- 等宽：`Font.recapTimestamp` / `.monospaced` 可用于行内 code / 代码块背景条
- 间距：`Spacing.sm/md`；圆角：`Radius.card`

## Diagnosis (for reviewers; executor must honor conclusions)

| 问题 | 结论 |
|------|------|
| 是否支持 Markdown？ | **否**。助手/用户均为 `Text(String)` 字面渲染 |
| 是能力缺失还是 bug？ | **产品未实现** + SwiftUI `String` vs `LocalizedStringKey` 陷阱 |
| 模型会不会输出 MD？ | 会。prompt 未禁止；LLM 默认偏结构化；联网/列表回答尤其明显 |
| 最小可行路径？ | 系统 `AttributedString(markdown:options:)` + 助手侧专用 View + 流式防抖；**零新 SPM** |
| 完整 GFM？ | **本计划不做**（表格/GFM 勾选列表/语法高亮另案） |

### Approach decision (locked)

**采用方案 A（推荐，本计划执行）**：Foundation `AttributedString` + SwiftUI `Text`，仅助手气泡；用户气泡保持字面（用户输入几乎无 MD，且误解析风险更高）。

**拒绝方案 B（本计划）**：引入 MarkdownUI / PicoMarkdownView / Hairball —— 能力更强，但增加依赖面、主题定制成本、与 Recap 青瓷视觉磨合；仅当方案 A 在真机上列表/标题不可读时再开 follow-up（036）。

**拒绝方案 C**：自写正则高亮 —— 易碎、难测、与流式半成品语法冲突。

### Supported subset (v1 contract)

Must render when complete (streaming may briefly show raw mid-token):

1. `**bold**` / `*italic*` / `***both***`
2. `` `inline code` ``
3. Links `[title](url)`（走系统 / `OpenURLAction`；会议外链可外开）
4. Unordered / ordered lists（依赖 `.full` interpretedSyntax 的 PresentationIntent；若系统对中文混排列表表现差，允许降级为保留换行的近纯文本，但 **不得** 把 `**` 当字面留下）
5. Soft line breaks / paragraphs

Explicitly **out of v1**:

- Tables、HTML、图片、` ``` ` 语法高亮主题、GFM task list、脚注、KaTeX

Incomplete fences during streaming: show buffered plain text for the unfinished fence body; do not crash; when stream ends, reparse once with full options.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd /Users/liuyong/Projects/Recap/RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Unit tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RecapUITests -only-testing:RecapLLMTests CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED（模拟器名按本机调整；若尚无 RecapUITests，见 Step 1） |
| No plain Text on assistant | `rg -n 'case \\.assistant:' -A 20 RecapApp/Modules/RecapUI/AgentInvokeSheet.swift \| rg 'Text\\(message\\.text\\)'` | **no matches** on assistant branch |
| Helper exists | `rg -n 'AskMarkdownText|AskMarkdownRenderer' RecapApp/Modules/RecapUI` | ≥1 |
| Prompt allows MD | `rg -n 'Markdown|加粗|列表' RecapApp/Modules/RecapLLM/Agent/AgentSystemPrompt.swift` | ≥1 |

## Suggested executor toolkit

- `swiftui-expert-skill`（若有）：气泡排版与 `fixedSize` / 选中复制行为。
- **不要**引入第三方 Markdown SPM，除非触发 STOP 条件后用户批准 036。

## Scope

**In scope**:

- `RecapApp/Modules/RecapUI/AskMarkdownText.swift`（新建）— 解析 + 渲染 View + 流式防抖 API
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — 助手分支改用 `AskMarkdownText`
- `RecapApp/Modules/RecapLLM/Agent/AgentSystemPrompt.swift` — 增加**受限** Markdown 输出约定（仍要求简洁，禁止大段装饰）
- `RecapApp/Tests/RecapUITests/AskMarkdownRendererTests.swift`（新建）— 纯函数解析测例
- `RecapApp/project.yml` — **仅当**需要新建 `RecapUITests` target 时增加；若已有则只加源文件
- `plans/README.md` — 状态行

**Out of scope**:

- 用户气泡 Markdown（保持 `Text(message.text)`）
- `AskBubble` / `ChatMessageRecord` schema 变更
- `AskConversationModel` 事件协议 / AgentKernel / transport
- `MinutesMarkdownParser`、纪要详情页、SkillsSheet、BriefSheet
- 第三方 Markdown 库、语法高亮、表格、图片
- Prototype（`RecapPrototype/.../AgentInvokeSheet.swift`）— 可选同步，非必须
- 复制按钮改富文本（继续复制源字符串 `message.text`）

## Git workflow

- Branch（若有 git）：`advisor/035-ask-chat-markdown`
- Commit style：祈使句短说明，例：`Render Ask assistant bubbles as constrained Markdown`
- Do NOT push / open PR unless operator asks

## Steps

### Step 1: 建立可测的解析层（无 UI 副作用）

新建 `RecapApp/Modules/RecapUI/AskMarkdownText.swift`：

```swift
import Foundation
import SwiftUI

enum AskMarkdownRenderer {
    /// 将助手回复 Markdown 转为可显示的 AttributedString。
    /// 解析失败时返回纯文字 AttributedString（永不抛到 UI）。
    static func attributed(_ source: String) -> AttributedString {
        let trimmed = source // 保留尾部空格有利于流式光标感；不要 trim 破坏增量
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(
            markdown: trimmed,
            options: options
        ) {
            return applyRecapTypography(parsed)
        }
        return AttributedString(trimmed)
    }

    /// 统一前景/字号，避免 Markdown 默认样式漂成系统蓝/大标题失控。
    private static func applyRecapTypography(_ input: AttributedString) -> AttributedString {
        var output = input
        // 遍历 runs：默认前景 recapInk；inlineCode → monospaced + 浅绿底（若 Attribute 可设）
        // 链接保留 .link，颜色用 recapCeladon
        // 不要把整段改成 headline 级字号；列表项保持 ~15pt
        return output
    }
}

struct AskMarkdownText: View {
    let source: String
    var isStreaming: Bool = false

    @State private var rendered: AttributedString = AttributedString()
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        Text(rendered)
            .font(.system(size: 15, weight: .regular, design: .default))
            .lineSpacing(4)
            .foregroundStyle(Color.recapInk)
            .tint(Color.recapCeladon)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .onChange(of: source, initial: true) { _, newValue in
                scheduleRender(newValue, streaming: isStreaming)
            }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    debounceTask?.cancel()
                    rendered = AskMarkdownRenderer.attributed(source)
                }
            }
    }

    private func scheduleRender(_ text: String, streaming: Bool) {
        if !streaming {
            debounceTask?.cancel()
            rendered = AskMarkdownRenderer.attributed(text)
            return
        }
        // 产品愿景：50ms 防抖；流式中合并重解析
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            rendered = AskMarkdownRenderer.attributed(text)
        }
    }
}
```

实现细节允许微调，但必须满足：

1. `AskMarkdownRenderer.attributed` 是 **同步纯函数**（便于单测）
2. 流式 **≥50ms** 防抖；流结束立即最终解析
3. 解析失败 → 纯文本，不崩溃
4. 链接 tint 用 `recapCeladon`，正文 `recapInk`

若 `RecapUI` 尚无测试 target：在 `project.yml` 增加 `RecapUITests`（镜像 `RecapLLMTests`），`dependencies: [RecapUI]`，`PRODUCT_BUNDLE_IDENTIFIER: com.recap.ui.tests`，然后 `xcodegen generate`。

新建 `RecapApp/Tests/RecapUITests/AskMarkdownRendererTests.swift`：

| 用例 | 输入要点 | 断言 |
|------|----------|------|
| bold | `"结论是 **通过**。"` | 结果字符串可见文字含「通过」且不含 `**`；或检查 stronglyEmphasized intent |
| inline code | `"用 \`mm:ss\` 标注"` | 可见文字无反引号围栏 |
| link | `"[议程](https://example.com)"` | 存在 `.link` == example.com |
| plain fallback | 随意正常中文 | 等于原文字面 |
| list smoke | `"- a\n- b"` | 不崩溃；可见含 a/b（允许系统插入列表标记） |

**Verify**:

```bash
cd /Users/liuyong/Projects/Recap/RecapApp && xcodegen generate
# 然后 test RecapUITests（destination 按本机）
rg -n "enum AskMarkdownRenderer|struct AskMarkdownText" RecapApp/Modules/RecapUI/AskMarkdownText.swift
```

→ 两者均存在；测试可编译（可先不跑全量）。

### Step 2: 接线 AgentInvokeSheet 助手气泡

在 `messageRow` 的 `.assistant` 分支，将：

```swift
Text(message.text)
    .font(...)
    .lineSpacing(4)
    .foregroundStyle(Color.recapInk)
    .fixedSize(horizontal: false, vertical: true)
```

替换为：

```swift
AskMarkdownText(source: message.text, isStreaming: message.isStreaming)
```

**保持**：`TypingDots` 空流式逻辑；降级提示 / steps / citations / 复制 / 追问不变。  
**用户分支**：继续 `Text(message.text)`。  
**复制**：仍 `UIPasteboard.general.string = message.text`（源 Markdown/原文，便于粘贴到备忘录再编辑）。

**Verify**:

```bash
rg -n 'AskMarkdownText\\(source:' RecapApp/Modules/RecapUI/AgentInvokeSheet.swift
# 助手分支不再 Text(message.text)：
python3 - <<'PY'
from pathlib import Path
p=Path('RecapApp/Modules/RecapUI/AgentInvokeSheet.swift')
t=p.read_text()
# crude: between 'case .assistant:' and next 'case ' or citation helpers
i=t.index('case .assistant:')
j=t.index('private func stepsRow', i)
chunk=t[i:j]
assert 'AskMarkdownText' in chunk
assert 'Text(message.text)' not in chunk
print('assistant markdown ok')
PY
```

### Step 3: 收紧 system prompt（鼓励有节制的 Markdown）

在 `AgentSystemPrompt.ask` 的「口头答复」句后追加（中文，保持短）：

```
排版：可用少量 Markdown（加粗关键结论、短列表、行内代码、链接）。不要标题堆叠、不要代码围栏灌水、不要表格。一句能说清就别列点。
```

不要删除「简洁 / 不要开场白 / 事实优先级」等既有纪律。

**Verify**:

```bash
rg -n 'Markdown|加粗关键结论' RecapApp/Modules/RecapLLM/Agent/AgentSystemPrompt.swift
```

→ ≥1；且仍含「不要开场白」。

### Step 4: 构建 + 单测 + 真机/模拟器冒烟清单

```bash
cd /Users/liuyong/Projects/Recap/RecapApp
xcodegen generate
xcodebuild -project RecapApp.xcodeproj -scheme RecapApp \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RecapUITests \
  CODE_SIGNING_ALLOWED=NO
```

手动冒烟（记录在 PR/完成说明，不写自动化 UITest）：

1. 问：「用三条要点总结刚才决议」→ 应见列表而非 `- ` 原文符号（或至少 `**` 被吃掉）
2. 问含链接场景（联网开时）→ 链接可点、色为青瓷
3. 流式过程中快速吐字 → 滚动仍跟手，无明显掉帧；结束后样式稳定
4. 「复制」粘贴到备忘录 → 仍是源文本（可含 `**`），可接受
5. 用户自己打 `**x**` → 用户气泡仍显示字面 `**x**`

## Test plan

- New file: `RecapApp/Tests/RecapUITests/AskMarkdownRendererTests.swift`
- Pattern: mirror `RecapApp/Tests/RecapModelsTests/MinutesMarkdownParserTests.swift` 风格（XCTest，`@Test` 若工程已用 Swift Testing 则跟现有 RecapLLMTests）
- Cases: bold / inline code / link / plain / list smoke / 解析失败不抛
- **不**测 SwiftUI View 生命周期；只测 `AskMarkdownRenderer.attributed`
- Verification: `xcodebuild test … -only-testing:RecapUITests` → 全绿

## Done criteria

Machine-checkable. ALL must hold:

- [x] `AskMarkdownText.swift` 存在且含 `AskMarkdownRenderer` + `AskMarkdownText`
- [x] 助手气泡使用 `AskMarkdownText`；用户气泡仍为 `Text(message.text)`
- [x] `AgentSystemPrompt.ask` 含受限 Markdown 约定
- [x] Simulator build SUCCEEDED
- [x] `RecapUITests`（或若放在现有 target 的等价测试）全绿
- [x] `rg "MarkdownUI|PicoMarkdownView|Hairball" RecapApp/project.yml` → no matches
- [x] 未改 `ChatMessageRecord` / `AskBubble` 字段形状
- [x] `plans/README.md` 本计划状态 → DONE

## STOP conditions

Stop and report back (do not improvise) if:

- Current-state excerpts drifted（助手已不是 `Text(message.text)`）。
- `AttributedString(markdown:options:)` 在 iOS 26 SDK 上对列表完全不可用，且加粗/链接也失败 → 报告后等待是否批准引入轻量库（另开 036），**本计划不要擅自加 SPM**。
- 流式防抖后主线程仍明显卡顿（需 Instruments 证据）→ 报告；可提议把解析挪到后台 `Task.detached` 再回主线程赋值，但若改动超过本计划 Scope，STOP。
- 为通过测试需要修改 AgentKernel / 持久化 schema。
- `RecapUI` 模块对测试 target 链接失败且无法用与 `RecapLLMTests` 相同模式解决。

## Maintenance notes

- 未来若上代码块高亮 / 表格：新开计划，优先评估 PicoMarkdownView（iOS 18+ 流式）而非复活维护模式的 MarkdownUI。
- 纪要页若也要 MD 预览：**不要**复用 `MinutesMarkdownParser`；可复用 `AskMarkdownText` 或抽到 `RecapUI/Markdown/`。
- Prompt 放宽后若模型开始「标题党」：在 `AgentSystemPrompt` 加负例，而不是在渲染层 strip。
- Reviewer 重点看：流式防抖、失败回退、链接颜色、用户气泡未误开 MD、复制仍为源字符串。
- Deferred：用户消息 MD、选中复制富文本、Prototype 同步、GFM 表格。
