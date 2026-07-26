# Plan 032: Skill 系统（SKILL.md 化 + `run_skill`）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Compare against live code. 确认：① `plans/029`
> 已 DONE；② `AgentRunRequest.allowedTools` + `AgentToolRegistry.filtered`
> 存在；③ `SkillsSheet` 仍用 `provider.streamText` 一句弱 prompt；
> ④ 无 `AgentSkill` / `run_skill` 类型。On mismatch, STOP.

## Status

- **State**: DONE（2026-07-25）— Build + Tests 全绿；Ask/`SkillsSheet` 人工冒烟留给用户
- **Priority**: P2
- **Effort**: M
- **Risk**: MED — skill 若放开写工具会静默改用户数据；本计划写工具默认不进 skill 白名单
- **Depends on**: `plans/029`（**硬**，工具集成形）；`plans/027`（硬，内核 + allowedTools）
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

`SkillsSheet` 六个硬编码技能各靠一句弱 prompt + 单次 `streamText`，结果不落库、
不可配置、与 Ask 内核完全隔离（`Agent化实施方案.md` §现状 / README 否决「就地改 prompt」）。

目标：skill = **system prompt + 允许工具子集 + 模型角色 + 步数预算**，
走同一 `AgentKernel`；Ask 可通过 `run_skill` 调用命名技能。

## Current state

- `RecapApp/Modules/RecapUI/SkillsSheet.swift` — 内嵌 6 技能；`runWithLLM` 用
  `LLMProviderFactory.makeCurrent().streamText`
- `AgentRunRequest.allowedTools: Set<String>?` + `registry.filtered(allowing:)` 已就绪
- 无 SKILL.md、无 `AgentSkill`、无 `run_skill`

### Design constraints

- **SKILL.md 是单一事实源格式**：frontmatter（id/name/…）+ body（system prompt）
- **内置 6 个技能**覆盖现有 UI（写作 3 + 提取 3）；文案可改进，**id 稳定**
- Skill **默认只允许只读工具**（`search_transcript` / `search_brief` /
  `list_action_items` / `get_meeting_minutes`）。**禁止**在内置 skill 白名单里放
  `create_reminders` / `revise_minutes` / `run_skill`（防静默写库与递归）
- `run_skill` 嵌套执行时：**剔除** `run_skill`，预算取 skill 自身（≤ `review()`）
- 结果仍以 SkillsSheet **预览**为主（不强制落库）；与 030「改纪要走 HITL」不冲突
- **不做**用户 GUI 编辑器 / 导入导出文件选择器（可 follow-up）；parser 要能吃字符串，
  便于日后 Documents 目录加载
- 内置内容以 Swift 字符串常量托管（避免 framework resource 拷贝坑）；格式仍是 SKILL.md，
  可用 parser 单测往返

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate | `cd RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild ... build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Tests | `xcodebuild test ... -only-testing:RecapLLMTests -only-testing:RecapModelsTests` | 全绿 |
| Skill 类型 | `rg -n 'struct AgentSkill' RecapApp/Modules/RecapLLM` | ≥1 |
| run_skill | `rg -n 'name: "run_skill"' RecapApp/Modules` | 1 |
| 旧 streamText 路径退出 Skills | `rg -n 'streamText' RecapApp/Modules/RecapUI/SkillsSheet.swift` | 0 |

## Suggested executor toolkit

- 对齐现有 `AgentTaskRunner` / `AskConversationModel` 的工具装配风格
- **禁止**：给内置 skill 开写工具；嵌套 `run_skill` 无限递归；在本计划做 033/034；
  把 Claude Code 的第三方 skill 直接塞进运行时

## Scope

**In scope**:

- `RecapLLM/Agent/Skills/AgentSkill.swift` — 值类型
- `RecapLLM/Agent/Skills/AgentSkillDocument.swift` — SKILL.md 解析
- `RecapLLM/Agent/Skills/AgentBundledSkills.swift` — 6 个内置文档
- `RecapLLM/Agent/Skills/AgentSkillCatalog.swift` — 分组列表 / 按 id 查找
- `RecapLLM/Agent/Skills/AgentSkillRunner.swift` — 顶层跑 skill → 收集答案
- `RecapLLM/Agent/Tools/RunSkillAgentTool.swift` — Ask 可调
- `AgentBudget.skill(maxSteps:)`
- 重写 `SkillsSheet` 走 runner；`MeetingNoteView` 传入会议上下文
- `AskConversationModel` review 路径注册 `run_skill`（只读基座工具）
- 测试：`AgentSkillDocumentTests`、`AgentSkillCatalogTests`
- `plans/README.md` / `Agent化实施方案.md` 032 = DONE

**Out of scope**:

- Skill GUI 编辑器、iCloud 同步、第三方 skill 商店
- 发言教练 skill（`LLM层实施方案.md` 另项）
- 把调研 prompt（031）迁成 skill（可 follow-up）
- 033 / 034

## Steps

### Step 1: `AgentSkill` + SKILL.md 解析器

```swift
public struct AgentSkill: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let icon: String          // SF Symbol
    public let groupId: String       // write | extract
    public let groupTitle: String
    public let systemPrompt: String
    public let allowedTools: Set<String>
    public let modelRole: AgentModelRole  // 默认 .quick
    public let maxSteps: Int              // 默认 3，硬顶 6
}
```

Frontmatter 键：`id` `name` `description` `icon` `group` `groupTitle`
`modelRole`（`quick`/`flash`→quick，`deep`→deep）`maxSteps` `allowedTools`
（逗号分隔）。body = systemPrompt。缺必填键 → 抛错。

`AgentBudget.skill(maxSteps:)`：`maxSteps` clamp 1…6；
`maxToolCalls = maxSteps + 2`；`wallClock = 20 * maxSteps`；
结果字符上限对齐 `review()`。

**Verify**: 解析完整文档、缺 `id` 失败、`flash`→`.quick`、`maxSteps` 封顶 6

### Step 2: 内置 6 skill + Catalog

将现有 SkillsSheet 六个技能写成 SKILL.md 字符串（中文 system，要求基于转写、
不编造）。默认 `allowedTools`:
`search_transcript,search_brief,list_action_items`。
「纪要精简 / 决策 / 未决」可加 `get_meeting_minutes`（若工具名在注册表存在——
本场用 `currentMinutes` 注入即可，**不要**依赖跨会 `get_meeting_minutes` 除非
workspace 非空；内置白名单用本场可读工具名：若无本场专用工具，system 里写
「用户消息已附本场转写/纪要摘要」）。

简化：**内置一律** `search_transcript, search_brief, list_action_items`。
Runner 在 user 消息中附带转写摘录（截断）与可选纪要 TLDR，减少对工具的硬依赖。

`AgentSkillCatalog.bundled` 按 group 分组；`skill(id:)` 查找。

**Verify**: catalog 恰好 6 个；两组 write/extract；id 无重复

### Step 3: `AgentSkillRunner` + 重写 `SkillsSheet`

Runner：

1. `AgentTransportFactory.makeCurrent(role: skill.modelRole)`
2. 装配只读工具注册表（与 Ask 本场只读子集一致，再 `filtered(allowing: skill.allowedTools)`）
3. `AgentKernel.run`，budget = `.skill(maxSteps: skill.maxSteps)`，thinking disabled
4. 收集 `textDelta` / `finished.answer`；取消可中断

`SkillsSheet`：列表来自 catalog；运行走 runner；展示步骤摘要可选一行 status；
**删除** `streamText` 路径。无 Key 时仍明确失败提示。

`MeetingNoteView` 传入：`segments` / `speakers` / `briefSources` / `meetingId` /
`actionItems` / `minutesSummary`（或等价），供 `AgentToolContext`。

**Verify**: `rg streamText SkillsSheet` → 0；Build 过

### Step 4: `run_skill` 工具

```text
name: run_skill
parameters: { "skill_id": string, "hint": string? }
```

- 查 catalog；未知 id → 明确错误
- 嵌套 `AgentSkillRunner`（或内联同等逻辑），registry **不含** `run_skill`
- `uiSummary`: `技能 · \(name)`
- 在 `AskConversationModel` 的 review（及 live 可选）注册；live 若成本敏感可只
  review 注册——**本计划：review + live 都注册**，但 skill maxSteps≤3

**Verify**: `name: "run_skill"` 一处；单测未知 id / 成功路径（Mock transport 可选，
至少测参数校验 + catalog 查找）

### Step 5: 测试与收尾

- `AgentSkillDocumentTests`、`AgentSkillCatalogTests`（可含 runner 参数装配纯函数）
- README / 实施方案 032 = DONE
- Step 6 人工：点「客户跟进邮件」→ 可见工具步或直接成文；Ask「用行动清单技能整理」
  → 轨迹含 `run_skill`

## Done criteria

- [x] SKILL.md 解析器 + 6 内置 skill + catalog
- [x] SkillsSheet 走 AgentKernel，无 `streamText`
- [x] `run_skill` 注册进 Ask；嵌套不含 `run_skill`
- [x] 内置 skill 无写工具
- [x] Build + Tests 绿；README DONE

**Follow-up**：Documents 热加载 / GUI 编辑器；031 调研 prompt 收成 skill；发言教练 skill。

## STOP conditions

- 内置 skill 白名单含写工具 / `run_skill` → STOP
- 嵌套执行不剔除 `run_skill` → STOP
- 继续用 `streamText` 双轨并行「先顶着」→ STOP（必须切内核）
- 做 GUI 编辑器或 033/034 → STOP
- `maxSteps` 允许 >6 → STOP

## Maintenance notes

- 031 的 `AgentResearchPrompt` 可在 follow-up 收成 `research-follow-up` skill
- Documents 目录热加载只需：目录枚举 + 同一 parser
- 第三方 Claude skill **不能**原样安装；只借用结构原则
