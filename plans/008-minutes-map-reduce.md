# Plan 008: 长转写 map-reduce 纪要——取代静默头尾截断

> **Executor instructions**: Follow step by step; verify; STOP on drift.
> Update `plans/README.md` when done.
>
> **Drift check**: Confirm `MinutesPipeline.cappedTranscript` still drops the
> middle at 14_000 chars and both summary/todos use `deepSeekFlash`. If
> map-reduce already exists, STOP.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: MED — 费用/延迟上升；reduce 合并易重复
- **Depends on**: plans/010-verification-baseline.md（硬依赖：先有 `cappedTranscript`/切块纯函数测试）；plans/004（软：失败勿用 Demo 掩盖）
- **Category**: bug
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

`LLM层实施方案.md` §2.5 要求说话人/语义边界切块 + map-reduce + citation。实现却是超 14k 字保留 35% 头 + 65% 尾，**中间整段丢弃**，且 UI 无覆盖率提示。多小时会的拍板常在中段 → 决议/待办系统性漏项。这是纪要「性质」问题，不是文案润色。

## Current state

```92:100:RecapApp/Modules/RecapLLM/MinutesPipeline.swift
    public static func cappedTranscript(_ text: String, maxChars: Int = 14_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let headLen = maxChars * 35 / 100
        let tailLen = maxChars - headLen
        let head = trimmed.prefix(headLen)
        let tail = trimmed.suffix(tailLen)
        return "\(head)\n\n…（中间转写已省略）…\n\n\(tail)"
    }
```

纪要与待办均 `LLMPresets.deepSeekFlash`（`:33,:50`）。方案要求纪要/待办走 `deepseek-v4-pro`（`LLMPresets.deepSeekPro` 已定义）。

短会（低于阈值）应**整段直喂**，避免无谓费用。

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Tests | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RecapLLMTests`（以 010 实际 scheme/destination 为准） | 全绿 |
| Build | Simulator build CODE_SIGNING_ALLOWED=NO | BUILD SUCCEEDED |

## Scope

**In scope**:
- `RecapApp/Modules/RecapLLM/MinutesPipeline.swift`
- 新建 `RecapApp/Modules/RecapLLM/TranscriptChunker.swift`（纯函数切块）
- 新建/扩展测试：`RecapLLMTests`（010 创建）
- `RecapApp/Modules/RecapUI/MeetingSession.swift`（可选：把 `coverageNote` 写入 `statusMessage`）
- `LLM层实施方案.md` §1.1/§2.5 一句标注「map-reduce 已在 RecapApp 落地」或「阈值/模型以代码为准」——仅改与本计划冲突的过时句，勿重写全文

**Out of scope**:
- Agent 多步 tool loop / 联网搜索
- 会前底稿注入（独立方向）
- Skills 全文封顶（可复用 chunker，但本计划只改 MinutesPipeline；若 Skills 一行可接 `cappedTranscript` 可顺手）
- 改 RecapASRBench 副本

## Steps

### Step 1: TranscriptChunker 纯函数

```swift
public enum TranscriptChunker {
    /// 按行（「说话人：文本」）切块；单块不超过 maxChars；尽量在说话人切换处断开。
    public static func chunk(_ transcript: String, maxCharsPerChunk: Int = 6_000) -> [String]
    /// 是否需要 map-reduce（总长 > threshold）
    public static func needsMapReduce(_ transcript: String, threshold: Int = 14_000) -> Bool
}
```

规则：
- 按 `\n` 行累积，超过 `maxCharsPerChunk` 时在边界 flush
- 单行超长则硬切
- 空转写 → `[]`

**Verify**: 单测：短文本 1 chunk；长文本多 chunk 且 `joined` 覆盖原文字符（允许边界空白差异）；中间内容出现在某一 chunk（回归「不丢中段」）。

### Step 2: Map 阶段结构化抽取

对每个 chunk 调用 `extractViaTool` 或短 prompt JSON，产出：

```swift
struct ChunkMinutes partial: Codable {
  var theme: String?
  var decisions: [String]
  var open_questions: [String]
  var action_items: [TodoListPayload.Item] // 复用已有 Item 字段，含 evidence_quote / start_seconds
}
```

并发：`withTaskGroup` 限制最大并发 3，避免打爆限流。模型：map 用 `deepSeekFlash`；若费用敏感可接受。

失败的 chunk：跳过并记 warning，不致整管线失败。

### Step 3: Reduce 合并

用 `deepSeekPro`（若 Key 仅支持 flash 的供应商则 fallback flash——通过 `LLMSelection.selectedModel` 或 try/catch）流式生成最终 Markdown，user 含：

- 各 chunk 的 theme/decisions/open_questions/action_items JSON
- 指示：去重、合并相近待办、保留 citation（evidence_quote + start_seconds）、输出格式与现有 `summarySystem` 一致

待办：也可对 map 的 action_items 做本地去重（task+owner 相似度）再交给 reduce 精修；或 reduce 只出纪要、待办用合并列表经一次 `extractViaTool`。

**推荐最小闭环**（降低复杂度）：

1. 短会（`!needsMapReduce`）：保持现有并行 streamText + extractViaTool，但**去掉截断丢中**（直喂）；模型改纪要 `deepSeekPro`、待办 `deepSeekFlash` 并行（与方案对齐）。
2. 长会：map chunks → reduce 纪要流式 → 合并待办列表（本地去重 + 可选一次 flash 精炼）。

保留 `cappedTranscript` 仅作 **Ask 回退** 或紧急保险，**MinutesPipeline.run 长路径不得再调用它丢中段**。

**Verify**: `rg -n "cappedTranscript" RecapApp/Modules/RecapLLM/MinutesPipeline.swift` → `run` 内长路径不再用于丢弃中间；短路径可不调用或调用但 threshold 以下恒等。

### Step 4: UI 覆盖率提示

`MinutesEvent` 增加 `case coverage(String)` 或在 `summaryReady` 前 yield failed/warning：`长会已分 N 段整理，覆盖全文`。`MeetingSession` 写入 `statusMessage` 数秒。

**Verify**: 构造超长假转写（重复行）跑 smoke（有 Key 时）或单测 chunk 数。

### Step 5: 文档与构建

改 `LLM层实施方案.md` 过时「业务代码为零」若仍存在则改为已落地对照一句；§2.5 标注实现位置 `MinutesPipeline`/`TranscriptChunker`。

Build + tests 全绿。

## Test plan

在 `RecapLLMTests`：

1. `chunk` 空/短/跨说话人/超长单行
2. `needsMapReduce` 边界 14000
3. 拼接所有 chunks 包含原字符串中段抽样（取原 index 中点 200 字，断言某个 chunk contains）

集成：有 Key 时可选手工长转写；无 Key 不强制。

## Done criteria

- [ ] 长转写不再头尾省略丢中段
- [ ] 短转写仍整段直喂且行为回归（冒烟）
- [ ] 纪要路径使用 pro（或文档与代码同时改为 flash 的明确产品决策——二选一，默认改代码用 pro）
- [ ] 单测覆盖 chunker
- [ ] Build + test 绿；README DONE

## STOP conditions

- `extractViaTool` 无法支持自定义 ChunkMinutes schema 且改动需重写 OpenAICompatibleProvider → STOP 报告
- DeepSeek Think/`tool_choice` 冲突再次出现 → map 改用纯 JSON `streamText` + 本地解析，勿死磕 tool
- 费用不可接受 → 先落地 chunker + 顺序 map（并发=1）+ 本地合并待办，reduce 仅一段

## Maintenance notes

- Reviewer：对比短会延迟是否回退；citation 的 `start_seconds` 是否在分块后仍合理（块内相对时间 vs 绝对——输入行若无时间戳则保持现状）。
- Deferred：按真实 `TranscriptSegment` 数组切块（优于拼好的字符串）；会前底稿坐标系。
