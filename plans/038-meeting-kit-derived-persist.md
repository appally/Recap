# Plan 038: 本场会册 Wave B —— Skill 落库 + Ask 钉选（衍生持久化）

> **Executor instructions**: Follow step by step. Do not start until
> `plans/037-meeting-kit-unified-materials.md` is DONE（会册两面 + Index 已存在）。
> On STOP conditions, report — do not improvise.
>
> **Drift check**: Confirm `MeetingKitIndex` exists and BriefSheet 已有衍生面；
> confirm `OutputKind` 仍无 `.skill` / `.clip`。若 037 未完成，STOP。

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED（schema / OutputKind）
- **Depends on**: **037 硬**
- **Category**: direction
- **Planned at**: workspace snapshot 2026-07-26（无 git SHA）

## Why this matters

037 修好「调研可找回」。仍蒸发的是：Skill 结果（内存）与值得保留的 Ask 答案。二者应进会册**衍生**面，且遵守「不进 Minutes 前缀」。

## Product decision（写死）

1. **本波最多新增 1 个 `OutputKind`**（推荐名：`clip`——通用「附页快照」），用 payload 内 `clipKind: skill | pinnedAnswer` 区分。  
   - **禁止**同时加 `.skill` + `.pin`。  
   - **禁止**用 `.draft` 存 skill（与 `ResearchDraft` 解码冲突）。  
   - **禁止**用 `.skill` 存 pin。
2. **钉选 = 复制写入 `AIOutput(kind: .clip)`**，**不**给 `ChatMessageRecord` 加 `pinned` 字段（避开 SwiftData 迁移 / 删库陷阱）。取消钉选 = 删除对应 clip output（或标记 payload `trashed`，优先删除简单）。
3. 同 `skillId` 再次跑 Skill：默认 **追加** 新版本 output（保留历史）；UI 衍生面按 `createdAt` 倒序。若产品要覆盖，另议——本波追加。
4. 注入纪律：clip **永不**进入 `BriefPromptBuilder`。

## Scope

**In scope**:

- `RecapApp/Modules/RecapModels/AIOutput.swift` — 增加 `case clip`
- 新建 `RecapApp/Modules/RecapModels/MeetingClip.swift`（或同文件）— `MeetingClipPayload: skillId?/title/markdown/sourceMessageId?/clipKind`
- `MeetingKitIndex` — derived 纳入 `.clip`
- `SkillsSheet.swift` / Ask 气泡菜单 — 成功后 insert；「钉到会册」
- 会册衍生面 — 打开只读预览（可用现有 Ask Markdown 渲染辅助若存在）
- 单测：payload roundtrip + Index 含 clip
- `plans/README.md` 状态

**Out of scope**:

- ChatMessageRecord schema 变更
- 滚动定位到 Ask 原气泡（预览全文即可）
- 本地通知、分享打包、改纪要自动吸收 clip
- 清理未使用的 `OutputKind.todos/decisions`（另案）

## Steps

### Step 1: `OutputKind.clip` + payload

```swift
public enum OutputKind: String, Codable, Sendable {
    case summary, todos, decisions, draft, clip
}

public enum MeetingClipKind: String, Codable, Sendable {
    case skill
    case pinnedAnswer
}

public struct MeetingClipPayload: Codable, Sendable {
    public var clipKind: MeetingClipKind
    public var title: String
    public var markdown: String
    public var skillId: String?
    public var sourceMessageId: UUID?
}
```

`AIOutput` 增加 `clipPayload` 计算属性（对称 `researchDraftPayload`）。

**Verify**: Models 单测 encode/decode；`rg -n "case clip" RecapApp/Modules/RecapModels/AIOutput.swift` 有命中。

### Step 2: Skill 成功路径落库

在 `SkillsSheet`（或实际完成回调处）成功后：

```swift
let data = try JSONEncoder().encode(MeetingClipPayload(...))
modelContext.insert(AIOutput(kind: .clip, payloadData: data, modelId: ..., promptHash: skillId, meeting: meeting))
try? modelContext.save()
```

需要把 `meeting` / `modelContext` 传入 SkillsSheet（若尚未有——对照 `AgentInvokeSheet` 如何持有 meeting）。

**Verify**: 跑一次 Skill → `meeting.outputs` 含 `.clip`；会册衍生可见。

### Step 3: Ask「钉到会册」

助手气泡菜单增加「钉到会册」→ 写 `.clip` / `pinnedAnswer`。  
衍生面打开只读预览；「从会册移除」删除该 output。

**Verify**: 钉选 → 关 Ask → 会册可见；移除后消失。无 Chat schema diff。

### Step 4: Index + 文档

`MeetingKitIndex.build` derived 包含 clip。  
更新 037 维护说明若需要。README 038 DONE。

**Verify**: Index 测试新例；Build + Models tests 过。

## Done criteria

- [ ] 仅新增 **一个** OutputKind：`clip`
- [ ] Skill 与钉选均以 clip 落库并可在会册衍生打开
- [ ] 未修改 `ChatMessageRecord` 字段
- [ ] clip 未进入 BriefPromptBuilder
- [ ] 测试与 BUILD 通过；README DONE

## STOP conditions

- 037 未完成
- 试图加两个 kind 或改 Chat pinned 字段
- 把 clip 当纪要前缀注入
- 迁移策略变成静默删用户库且未报告

## Maintenance notes

- 若未来 clip 类型变多，只扩 `MeetingClipKind`，不动 `OutputKind`。
- Reviewer：SkillsSheet 是否在无 modelContext 时静默丢结果（应明示失败）。
