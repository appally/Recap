# Plan 004: 诚实失败态——禁止 ASR/LLM 静默切演示冒充成功

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: Open Scope files and confirm "Current state"
> excerpts still match. If `startRecordingOrMock` no longer auto-calls
> `startMockStream()` on catch, or `MinutesPipelineSmoke.hasAPIKey` already
> delegates to current provider, STOP and report (may already be fixed).

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — 需保留 DEBUG/验收用的显式演示入口，但不能默认冒充 LIVE
- **Depends on**: none
- **Category**: bug
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

长会工具的信任前提是「失败可见」。当前 ASR `start()` 失败会静默 `startMockStream()`（演示剧本），无 DeepSeek Key 时又用演示纪要/待办冒充生成成功；同时 `hasAPIKey` 只认 DeepSeek，BYOK 通义/Kimi 等也会掉进演示。用户以为在录真会，结束却基于假台词出纪要——这比硬失败更糟。

## Current state

- `RecapApp/Modules/RecapUI/MeetingSession.swift` — LIVE/PROCESS 状态机；失败静默 Demo
- `RecapApp/Modules/RecapLLM/MinutesPipelineSmoke.swift` — `hasAPIKey` 只查 DeepSeek
- `RecapApp/Modules/RecapModels/AIServicePreferences.swift` — `LLMSelection.hasAPIKey(for:)` 已按模板查 Keychain
- `RecapApp/Modules/RecapLLM/LLMProviderFactory.swift` — `makeCurrent()` 是真实可用性门闩
- `RecapApp/Modules/RecapUI/TranscriptBlock.swift` — `DemoContent` 演示脚本/纪要
- `RecapApp/真机验收清单.md` — 仍可能依赖演示路径；改完后需改对应勾选项文案

### Excerpt: silent mock on ASR failure

```120:143:RecapApp/Modules/RecapUI/MeetingSession.swift
    private func startRecordingOrMock() async {
        let session = RecordingSession()
        // ...
        do {
            try await session.start()
            isUsingMockAudio = false
            statusMessage = ""
        } catch {
            recording = nil
            isUsingMockAudio = true
            statusMessage = ""
            startMockStream()
        }
    }
```

### Excerpt: DeepSeek-only gate

```16:19:RecapApp/Modules/RecapLLM/MinutesPipelineSmoke.swift
    public static var hasAPIKey: Bool {
        guard let key = KeychainStore.get(LLMPresets.deepSeekKeychainAccount) else { return false }
        return !key.isEmpty
    }
```

### Excerpt: correct per-template check already exists

```325:330:RecapApp/Modules/RecapModels/AIServicePreferences.swift
    public static func hasAPIKey(for template: LLMProviderTemplate) -> Bool {
        guard let key = KeychainStore.get(template.keychainAccount), !key.isEmpty else {
            return false
        }
        return true
    }
```

### Design constraints

- 产品原则：失败可恢复、不伪造成功。
- `DemoContent` 可保留，但**仅**经显式入口（DEBUG 菜单或设置「载入演示」）启用。
- 门闩必须与 `LLMProviderFactory.makeCurrent()` 一致：能 `makeCurrent()` 才进真 LLM；否则错误态，不写演示纪要。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate project | `cd /Users/liuyong/Projects/Recap/RecapApp && xcodegen generate` | exit 0 |
| Build | `xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |

## Scope

**In scope**:
- `RecapApp/Modules/RecapUI/MeetingSession.swift`
- `RecapApp/Modules/RecapLLM/MinutesPipelineSmoke.swift`
- `RecapApp/Modules/RecapUI/MeetingNoteView.swift`（错误态 UI：重试 / 结束并丢弃 / 可选「改用演示」若已有入口则接上）
- `RecapApp/Modules/RecapUI/AgentInvokeSheet.swift`（若仍用 `MinutesPipelineSmoke.hasAPIKey`，改为新门闩）
- `RecapApp/Modules/RecapUI/SkillsSheet.swift`（同上）
- `RecapApp/Modules/RecapUI/RecapUI.swift`（若用 `hasAPIKey` 展示）
- `RecapApp/真机验收清单.md`（同步「演示须显式开启」一句）

**Out of scope**:
- 种子会议 `RecapDataContainer.seedIfNeeded`（另案；本计划不删种子）
- 音频落盘 / LIVE 检查点（plans 005/007）
- map-reduce（plan 008）
- 会中 ASR 热切换引擎

## Git workflow

- 无 `.git` 时跳过 branch/commit；有 git 时分支名 `advisor/004-honest-failure`
- 勿 push / 勿开 PR，除非操作者明确要求

## Steps

### Step 1: 统一「当前 LLM 可用」门闩

在 `MinutesPipelineSmoke`（或更好：`LLMProviderFactory`）增加：

```swift
public static var canRunMinutesPipeline: Bool {
    (try? LLMProviderFactory.makeCurrent()) != nil
}
```

将 `hasAPIKey` 改为调用上述逻辑，或标记 deprecated 并全局替换调用点为 `canRunMinutesPipeline`。**禁止**再只读 DeepSeek account。

`MeetingSession.startProcessing` 改为：

```swift
if MinutesPipelineSmoke.canRunMinutesPipeline {
    startLLMProcessing(...)
} else {
    // 不再 startMockReveal；进入可恢复错误
    statusMessage = "未配置可用的大模型密钥（设置 → 大模型）"
    finishReviewWithoutMock() // 或停留 processing 并暴露「去设置」——二选一，优先进 review 空纪要 + 明确 statusMessage
}
```

删除/停用无 Key 时的 `startMockReveal` 自动路径。可将 `startMockReveal` 改名为 `startExplicitDemoReveal` 且仅从 DEBUG 入口调用。

**Verify**: `rg -n "deepSeekKeychainAccount" RecapApp/Modules/RecapLLM/MinutesPipelineSmoke.swift` → `hasAPIKey`/`canRunMinutesPipeline` 体中不再单独以 DeepSeek 为唯一条件；`rg -n "startMockReveal" RecapApp/Modules/RecapUI/MeetingSession.swift` → 自动 `startProcessing` 路径无调用。

### Step 2: ASR 失败改为错误态，禁止自动 `startMockStream`

改 `startRecordingOrMock`：

```swift
} catch {
    recording = nil
    isUsingMockAudio = false
    statusMessage = "转写引擎启动失败：\(error.localizedDescription)"
    // 不调用 startMockStream()
    // 可选：@Published var liveFailure: Error? 供 UI 显示「重试」「结束」
}
```

保留 `startMockStream()` 方法，但仅通过新 API 暴露，例如：

```swift
public func startExplicitDemoLive() {
    isUsingMockAudio = true
    statusMessage = "演示字幕（非真实录音）"
    startMockStream()
}
```

在 `MeetingNoteView` LIVE 底栏：当 `!recording.isRunning && statusMessage` 含失败时，提供「重试」按钮调用重新 `startLive` 逻辑，以及（可选）仅 `#if DEBUG` 的「改用演示字幕」。

**Verify**: `rg -n "startMockStream\\(\\)" RecapApp/Modules/RecapUI/MeetingSession.swift` → 除 `startExplicitDemoLive`（或等价）外，catch 路径无调用。

### Step 3: 同步 Ask / Skills / 顶栏文案门闩

- `AgentInvokeSheet` / `SkillsSheet` / `RecapUI`：凡 `MinutesPipelineSmoke.hasAPIKey` 改为 `canRunMinutesPipeline`（或新名）。
- UI 文案「演示模式（未配置 API Key）」改为「未配置可用密钥」；有 Key 但 `makeCurrent` 因会员/网关失败时，展示 `error.localizedDescription`，**禁止**演示回答冒充成功（Ask 失败应显示错误，不注入 Demo 答）。

**Verify**: `rg -n "MinutesPipelineSmoke.hasAPIKey" RecapApp` → 无匹配（或仅 deprecated 转发一行）。

### Step 4: 验收清单与构建

更新 `真机验收清单.md`：增加「ASR 失败不得出现演示剧本除非 DEBUG 显式点选」；「仅配非 DeepSeek BYOK 也能出真纪要」。

**Verify**:

```bash
cd /Users/liuyong/Projects/Recap/RecapApp && xcodegen generate && \
xcodebuild -project RecapApp.xcodeproj -scheme RecapApp \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

→ `BUILD SUCCEEDED`

## Test plan

若 plan 010 已落地：为 `canRunMinutesPipeline` / 门闩逻辑加单测（mock Keychain 困难时可测纯函数包装）。本计划最低要求：构建通过 + 手工场景：

1. 无任何 LLM Key → 结束会议不出现 Demo 待办文案「出移动端评审方案」
2. 只配非 DeepSeek BYOK（若环境允许）→ 走真 LLM 或明确错误，不走 Demo
3. 拒绝麦权限 / 引擎超时 → 状态栏有错误，blocks 不出现 `DemoContent.script` 台词

## Done criteria

- [ ] ASR catch 路径不再调用 `startMockStream()`
- [ ] 无可用 `makeCurrent()` 时不再 `startMockReveal` / 不 persist Demo 待办
- [ ] `hasAPIKey` 不再只认 DeepSeek
- [ ] Simulator Debug build 成功
- [ ] `plans/README.md` 本行 Status → DONE

## STOP conditions

- `DemoContent` 被多处硬编码依赖导致无法去掉自动路径且改动需动 >8 个文件以外的模块 → STOP，报告调用图
- 发现产品方明确要求「无 Key 必须演示」的书面决策（本仓库迁移计划写的是降级，不是冒充成功）→ 仍实现显式确认门，勿静默

## Maintenance notes

- Reviewer 重点看：任何 `isUsingMockAudio = true` 的赋值是否仅来自显式演示入口。
- 后续 plan 005 检查点不得把 Demo 字幕当真实 segments 落盘，除非 `isUsingMockAudio` 且用户确认。
- Deferred：种子会议移出生产路径；DEBUG 设置页「载入演示会议」完整 UX。
