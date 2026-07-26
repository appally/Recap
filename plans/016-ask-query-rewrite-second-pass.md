# Plan 016: Ask 代码侧二次检索（查询改写，非 AgentLoop）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Confirm `plans/015-ask-chinese-retrieval.md` is
> **DONE** in `plans/README.md` and `AskQueryIntentClassifier` exists in
> `AgentTools.swift`. Confirm there is still **no** `actor AgentLoop` in
> `RecapApp/Modules`. If 015 is not DONE, STOP and execute 015 first.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — 多一次 LLM 调用增延迟/费用；必须严格 max_steps=1 改写 + 禁止 tool_choice
- **Depends on**: `plans/015-ask-chinese-retrieval.md`（硬）；`plans/013-ask-multi-turn-history.md`（软）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

即使中文分词改善，同义表达（「报价」vs「价格」「多少钱」）仍可能 0 hit。完整 `AgentLoop` + model-driven tools 被 003/012 否决（DeepSeek Think + 强制 tool_choice → 400）。本计划用**代码侧两步状态机**：本地检索 0 hit → 用 flash **只改写检索词**（单次非流式/短流式）→ 再检索 → 再生成。模型**不选择工具**，不碰 `tool_choice`。

## Current state

- Ask 路径：`prepareLocal` → optional web → `streamText` 生成
- `OpenAICompatibleProvider.extractViaTool` 仅待办用；注释写明 Think + tool_choice 400
- `LLMProvider` 可能已有 013 的多轮 `streamText`；本计划优先用**短** `streamText` 或新增 `completeText` 收集改写结果
- 015 后：意图芯片走时间窗/dossier；本计划只处理 `.keywordSearch` 且 transcript+brief 总 hit==0 的情况

### Design constraints（必须遵守）

- **禁止** `actor AgentLoop`、禁止 Ask 路径 `tool_choice`
- 改写最多 **1** 次；总检索轮次 ≤2
- 改写模型固定 `LLMPresets.deepSeekFlash`，temperature 0
- 改写失败/超时 → 退回现有 capped 全文路径，不阻断回答
- 默认仍不强制联网；web 逻辑保持 `AskWebRouter`

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild ... build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapLLMTests` | 新测全绿 |
| No AgentLoop | `rg -n "actor AgentLoop|class AgentLoop" RecapApp/Modules` | **no matches** |
| Rewrite helper | `rg -n "AskQueryRewriter|secondPass|rewriteQuery" RecapApp/Modules/RecapLLM` | ≥1 |

## Suggested executor toolkit

- 勿引入 langchain / MCP agent 框架
- 单测用纯函数解析改写输出，mock 不必起真网络（见 Step 3）

## Scope

**In scope**:

- `RecapApp/Modules/RecapLLM/AskQueryRewriter.swift` — **新建**
- `RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` — 编排 second pass（或由 sheet 调用 rewriter 后再 `prepareLocal`）
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift` — thinking 文案「换个说法检索…」；接线
- `RecapApp/Modules/RecapLLM/LLMProvider.swift` + `OpenAICompatibleProvider.swift` — **仅当**需要非流式 `completeText`；若可用现有 stream 收集完毕则可不改协议
- `RecapApp/Tests/RecapLLMTests/AskQueryRewriterTests.swift` — **新建**
- `plans/README.md`

**Out of scope**:

- 完整 ToolRegistry / model-driven multi-step agent
- 待办「让 AI 跟进」（另案 018）
- draftDocument / Skills
- 改变 web 提供商
- embedding

## Git workflow

- Branch: `advisor/016-ask-query-rewrite`
- Commit example: `feat: code-side Ask query rewrite on empty retrieval`
- No push/PR unless asked.

## Steps

### Step 1: `AskQueryRewriter` 纯解析 + prompt

```swift
public enum AskQueryRewriter {
    public static let system = """
    你是会议检索查询改写器。根据用户问题输出最多 3 个适合在转写里子串检索的关键词/短语。
    只输出一行，英文逗号分隔，不要解释，不要标点句号。
    """

    public static func parseKeywords(_ raw: String) -> [String] {
        // 按逗号/顿号/空白切，去空，去重，每项 2...20 字，最多 3 个
    }

    public static func shouldRewrite(
        intent: AskQueryIntent,
        localHitCount: Int
    ) -> Bool {
        intent == .keywordSearch && localHitCount == 0
    }
}
```

**Verify**: `rg -n "enum AskQueryRewriter" RecapApp/Modules/RecapLLM` → ≥1

### Step 2: 执行改写调用（无 tool）

在 `AgentInvokeSheet.askWithLLM`（推荐放 UI 编排层，runtime 保持纯函数）流程：

```
prepared = prepareLocal(query)
if AskQueryRewriter.shouldRewrite(intent, prepared.localHitCount) {
  thinkingLabel = "换个说法检索…"
  rewrittenLine = await collectStream(
    provider.streamText(system: AskQueryRewriter.system, user: query, model: flash, temperature: 0)
  )
  keywords = AskQueryRewriter.parseKeywords(rewrittenLine)
  if let joined = keywords.joined 非空 {
    prepared = prepareLocal(query: keywords.joined(separator: " "), ...) 
    // 注意：【问题】仍用用户原始 query；只让检索用改写词
  }
}
// 然后 web / streamAnswer 照旧；streamAnswer 的【问题】必须是用户原问
```

**关键设计**：`prepareLocal` 需支持 `retrievalQuery: String? = nil`——检索用 `retrievalQuery ?? query`，但 user 末尾【问题】始终是原始 `query`。若不愿改签名，可先 `prepareLocal(keywordsJoined)` 再把 user 里【问题】替换回原问（脆弱）。**优先加 `retrievalQuery` 参数**。

超时：改写收集可设约 8s；`Task.isCancelled` 则跳过。失败 catch 后继续原 prepared（可能走 capped）。

**Verify**: `rg -n "retrievalQuery" RecapApp/Modules/RecapLLM/AgentAskRuntime.swift` → ≥1

### Step 3: 单测（无网络）

`AskQueryRewriterTests.swift`：

- `testParseKeywordsCommaSeparated`
- `testParseKeywordsDedupAndCap3`
- `testShouldRewriteOnlyKeywordEmpty`
- `testShouldNotRewriteRecentWindowEvenIfEmpty`

**Verify**: RecapLLMTests 全绿

### Step 4: 守卫

确认：

```bash
rg -n "actor AgentLoop|tool_choice" RecapApp/Modules/RecapLLM/AgentAskRuntime.swift RecapApp/Modules/RecapLLM/AskQueryRewriter.swift
```

无 AgentLoop；Ask 改写路径无 tool_choice。

**Verify**: 上式无危险匹配；build SUCCEEDED

## Test plan

- 解析与 shouldRewrite 单测
- 手动（可选）：问一个与转写同义但用词不同的问题，thinking 出现「换个说法检索…」且第二次有 citation

## Done criteria

- [ ] `AskQueryRewriter` + `retrievalQuery` 参数存在
- [ ] 仅 `.keywordSearch && localHitCount==0` 触发一次改写
- [ ] 无 `AgentLoop`；Ask 路径无 tool_choice
- [ ] 测试与 build 绿
- [ ] `plans/README.md` 016 = DONE

## STOP conditions

- 015 未完成 → STOP
- 为实现改写而添加 multi-tool ChatQuery → STOP
- 改写次数做成可配置循环 >1 且无硬顶 → STOP（必须 max 1 rewrite）

## Maintenance notes

- 这是通往 Phase 2 AgentLoop 的「代码侧训练轮」；若未来上真正 ToolRegistry，可删除 rewriter，改为模型选 `search_transcript`。
- Reviewer：延迟是否可接受；【问题】是否始终为用户原文。
- 延期：待办 AI 跟进、read_url 深读、会话持久化。
