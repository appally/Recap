# Plan 048: 导出体系——逐字稿/SRT/PDF/长图，免费能力

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（2026-08-14 产品调研：导出锁付费是品类通病——讯飞免费版只有 TXT、用户用剪映
  绕路生成 SRT；免费导出是最便宜的口碑差异化，律师/记者刚需逐字稿交付）
- **Effort**: M
- **Risk**: LOW（全部纯函数 + 临时文件，不碰管线）
- **Depends on**: none
- **Category**: feature

## Why this matters

现状只有一处纯文本 ShareLink（`MeetingNoteView.swift:608`），转写/手写 Tab 显式隐藏分享钮
（`currentTabSupportsShare`）。导出体系四格式（带说话人逐字稿 / SRT / PDF / 长图）全部免费，
对标竞品付费墙。**格式真相源纪律**：`shareMarkdown` 构造器族 + `ActionItem.clipboardLine` 已被
测试钉死，导出体系必须调用它们，不得另起第三套格式（plan 028 取向：不在 View 里拼字符串）。

## Current state（勘察结论，2026-08-14 核实）

- **数据**：`TranscriptSegment`（RecapModels）有 Double 秒级 start/endSeconds——SRT 时间戳够用；
  但批处理引擎可能 start=0、end==start（未知），导出须排序 + clamp + end 兜底。
- **渲染底座**：`AskMarkdownRenderer.attributed`（AskMarkdownText.swift:346）已有
  markdown → AttributedString 纯函数；`MarkdownBlockParser.parse`（:28）支持 GFM 表格。
  PDF 路径 = 这两个 + `UIGraphicsPDFRenderer`（当前零使用）。
- **长图**：`ImageRenderer` 生产零使用；mermaid 块依赖 WKWebView（离屏快照拿不到）——
  **图示类内容导出降级为文本**是 v1 明确决策（MindmapOutlineView.swift:6 已有同款注释先例）。
- **临时文件**：无现成「写临时文件再分享文件」模式；temporaryDirectory 系统级不进 iCloud 备份
  （043 的 BackupExclusion 约束由选址天然满足）。
- **逐字稿数据源**：`reviewTranscriptBlocks`（MeetingNoteView:1337）语义应下沉为纯函数——
  `Meeting.segments` + `meeting.speakers` + `TranscriptBlock(segment:speakers:)` 的
  fallback 命名规则，保证导出与屏显一致。
- **AI 声明**：导出物带 `AILightDisclaimer` 文案「内容由 AI 生成，仅供参考」
  （MeetingNoteView:3424）——诚实框架的自然延伸；纯转写导出（SRT/raw）不带。

## Implementation

### Wave A: `MeetingExportComposer`（纯函数 + 单测，RecapModels）

新文件 `RecapApp/Modules/RecapModels/MeetingExportComposer.swift`：

```swift
public enum MeetingExportComposer {
    /// 带说话人标签逐字稿 Markdown：`[mm:ss] 名字：text`（与 startLLMProcessing 的
    /// transcript 格式一致，便于 LLM 复读；polished 优先 raw 回退 = feedText 语义）
    public static func transcriptMarkdown(segments: [TranscriptSegment], speakers: [Speaker]) -> String
    /// SRT：每 segment 一条；排序 + clamp；end<=start 时兜底 = min(下一句 start, start+估读)
    /// 估读 = max(1s, 字数 × 0.3s)。说话人名前缀可选参数。默认 raw 文本（字幕须与音频对齐，
    /// 润色稿会改写口癖，观感不符——勘察风险 5）。
    public static func srtContent(segments: [TranscriptSegment], speakers: [Speaker],
                                  speakerPrefix: Bool = false) -> String
    /// 临时文件落盘（temporaryDirectory + 文件名清洗），返回 URL。
    public static func writeTemporary(_ content: String, fileName: String) throws -> URL
}
```

SRT 时间戳格式 `HH:MM:SS,mmm`，**必须用 startSeconds/endSeconds 而非 parseTimestamp**
（后者 mm:ss 整数精度，勘察风险 1）。

### Wave B: PDF + 长图 composer（RecapUI）

新文件 `RecapApp/Modules/RecapUI/MeetingExportRenderers.swift`：

1. `MinutesPDFRenderer.render(markdown: String, title: String) -> Data`：
   `MarkdownBlockParser.parse` → 逐块 `AskMarkdownRenderer.attributed` → NSAttributedString →
   `UIGraphicsPDFRenderer` A4 分页绘制；页脚「内容由 AI 生成，仅供参考」小字。
   mermaid/思维导图块降级为代码文本（v1 决策）。
2. `MinutesLongImageRenderer.render(markdown: String, title: String) -> UIImage`：
   同一 attributed 块序列，单张 CGContext 逐块 `draw(with:)`（宽 750pt @2x）——**不用
   ImageRenderer 渲染整棵视图树**（长会内存风险，勘察风险 2）；长图只做纪要，逐字稿走
   文本/SRT/PDF。总高度上限（~16000pt）截断 + 尾注提示。

### Wave C: 入口 UI（MeetingNoteView）

- 分享钮（:608 ShareLink）改为 `Menu`：
  - **总结 Tab**：复制 Markdown（现状保留）/ 导出 .md / 导出 PDF / 导出长图。
  - **转写 Tab**：导出逐字稿 .md / 导出 SRT。（**放开 `currentTabSupportsShare` 对 .transcript
    的限制**——001 时代的「转写不可分享」是被推翻的产品决策：当时只能给总结文本才是理由，
    现在能给出真实转写交付物，不对称消除。记录在此作为对 plan 001 的正式修订。）
  - 手写 Tab 维持现状（画布本身是图形，另案）。
- 导出动作 = compose → writeTemporary / render → `ShareLink(item: URL)`（sheet 或
  `shareLink` item 状态驱动）。
- 文件命名：`\(meeting.title).md / .srt / .pdf / .png`（文件名清洗：`/` 全角化等）。

## Verification

1. `xcodegen generate` + 全量构建。
2. 单测（RecapModelsTests，与 ActionItemClipboardTests 同层）：
   - transcriptMarkdown：speaker fallback 命名、polished 优先、`[mm:ss]` 格式；
   - srtContent：排序、end<=start 兜底（下一句 start / 字数估读）、`HH:MM:SS,mmm` 格式、
     空段安全；
   - writeTemporary：文件名清洗（含 `/` 的标题）。
3. 手测：纪要导出 PDF 分页正常含页脚声明；转写导出 SRT 用 IINA/QuickTime 字幕加载验证时间轴。

## STOP conditions

- `AskMarkdownRenderer.attributed` 在无 SwiftUI 视图上下文中行为异常（如 emoji run 保护依赖
  environment）→ 停，改用裸 `AttributedString(markdown:)` 并记录能力差异。
- PDF 中文排版出现 CoreText 缺字（模拟器字体缺失）→ 停，真机验证后再继续。

## Considered and rejected

- **逐字稿长图**：ImageRenderer/CGContext 一次性渲染 3h 逐字稿内存超限；长图只做纪要。
- **mermaid/思维导图导出为图**：WKWebView 离屏快照不可靠，v1 降级文本（后续可用
  `WKWebView.takeSnapshot` 另案）。
- **Word (.docx) 导出**：需引入第三方库或手写 OOXML；v1 用 .md + PDF 覆盖交付场景，
  Word 待用户反馈再立项。
- **富文本复制**：035 已定调「复制永远给源 Markdown 字符串」，维持。
- **导出物带元信息头（日期/时长/地点）**：纪要 PDF 加 title + 日期一行；.md/SRT 不加
  （剪贴板/字幕消费方不要噪音）。
- **导出临时文件 BackupExclusion**：temporaryDirectory 系统级排除于 iCloud 备份，无需调用。
