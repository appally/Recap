# Plan 044: 四条 LLM 旁路去硬编码模型名 + 两处误导性「免费额度已用完」文案

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 510a7fa..HEAD -- RecapApp/Modules/RecapLLM RecapApp/Modules/RecapUI/AskConversationModel.swift RecapApp/Modules/RecapUI/MeetingSession.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `510a7fa`, 2026-08-14

## Why this matters

2026-08-02 修过「Agent 免费档三模型名打架」（网关下发 qwen-plus，代码却硬编码 DeepSeek 名 →
403），但当时只修了 Agent 主链路。本次审计发现**四条旁路仍在硬编码 `LLMPresets.deepSeekFlash`**：
云端档（Pro/免费，qwen 网关，模型白名单只有 qwen 系列）下这些请求全部 400/403——推荐问题静默
消失、检索改写跳过、Ask 兜底失败、**转写润色直接报错**。

同批修两处硬编码「免费额度已用完」文案：断网/Pro 验签失败的用户会被引导去「升级 Pro」——
这是 `RecapCredentialError.userMessage` 专门修过的问题在别的路径复发，而正确的工具函数就在
同一个文件里。

## Current state

**正确范本**（要复用的 API）— `RecapApp/Modules/RecapLLM/Agent/AgentTransportFactory.swift:84-97`：

```swift
    /// 按模板与角色解析模型名（不硬编码 DeepSeek）。
    /// 云端档(Pro/免费)统一以网关下发的 cred.llmModel 为准——与 Minutes 路径同一来源,...
    public static func modelName(for template: LLMProviderTemplate, role: AgentModelRole) -> String {
        if AIServiceMode.current != .byok {
            return (try? RecapCredentialProvider.shared.current())?.llmModel ?? LLMPresets.cloudDefaultModel
        }
        if template == .deepseek {
            switch role {
            case .quick: return LLMPresets.deepSeekFlash
            case .deep: return LLMPresets.deepSeekPro
            }
        }
        return LLMSelection.selectedModel ?? template.defaultModel
    }
```

该函数与 `LLMProviderFactory.makeCurrent()` / `makeDefaultDeepSeek()` 的 provider 选择语义逐分支
对应（云端→网关 provider+cred.llmModel；BYOK deepseek→DeepSeek 端点+flash/pro；BYOK 其它→
所选端点+selectedModel）——所以「provider 用 makeCurrent/makeDefaultDeepSeek + 模型名用
modelName()」组合在任何档位都自洽。

**四个违规点**（provider 与模型名错配）：

1. `RecapApp/Modules/RecapLLM/SuggestedQuestionsGenerator.swift:79-84`：

```swift
            let provider = try LLMProviderFactory.makeCurrent()
            let stream = provider.streamText(
                system: system,
                user: composeUser(stage: stage, dossier: dossier),
                model: LLMPresets.deepSeekFlash,
                temperature: 0
            )
```

2. `RecapApp/Modules/RecapUI/AskConversationModel.swift:1062-1067`（`rewriteRetrievalQuery`，同构）：

```swift
            let provider = try LLMProviderFactory.makeCurrent()
            let stream = provider.streamText(
                system: AskQueryRewriter.system,
                user: query,
                model: LLMPresets.deepSeekFlash,
                temperature: 0
            )
```

3. `RecapApp/Modules/RecapLLM/AskMeetingDossier.swift:103-111`（`AskModelRouter`）：

```swift
public enum AskModelRouter {
    public static func model(for phase: MeetingPhase) -> String {
        switch phase {
        case .live, .processing:
            return LLMPresets.deepSeekFlash
        case .review:
            return LLMPresets.deepSeekPro
        }
    }
}
```

   调用方 `AskConversationModel.swift:1004` 附近：`provider = try LLMProviderFactory.makeCurrent()`
   后以 `AskModelRouter.model(for:)` 的返回值作为 model 传入。

4. `RecapApp/Modules/RecapUI/MeetingSession.swift:1534-1543`（转写润色）：

```swift
            let provider = try await Task.detached(priority: .userInitiated) {
                try LLMProviderFactory.makeDefaultDeepSeek()
            }.value
            let polisher = TranscriptPolisher { system, user in
                provider.streamText(system: system, user: user,
                                     model: LLMPresets.deepSeekFlash, temperature: 0.1)
            }
            let polished = try await polisher.polish(source)
            meeting.polishedSegmentsData = try? JSONEncoder().encode(polished)
            meeting.polishedModelId = LLMPresets.deepSeekFlash
```

**两处硬编码文案**：

5. `RecapApp/Modules/RecapUI/MeetingSession.swift:1238-1244`（`startProcessing` 免费档强刷失败）：

```swift
                } catch {
                    self.statusMessage = "免费额度已用完，升级 Pro 或解锁自备密钥以继续生成纪要"
                    self.finishReviewWithoutMock()
                }
```

   同文件 40 行内就有正确工具（`:746-752`）：

```swift
    private static func quotaFailureMessage(_ error: Error) -> String {
        (error as? RecapCredentialError)?.userMessage ?? "凭证准备失败，请检查网络后重试"
    }
```

6. `RecapApp/Modules/RecapUI/MeetingSession.swift:850-852`（`performRetranscribe` 403 分支）：

```swift
        } catch RecapCredentialError.issueFailed(let status, _) where status == 403 {
            statusMessage = "免费额度已用完，升级 Pro 或解锁自备密钥后再试"
            return false
        }
```

`RecapCredentialError.userMessage`（`RecapApp/Modules/RecapModels/RecapCredentialProvider.swift:38-63`）
解析网关 403 body 区分 `quota_exceeded` / `requires_membership` 并按 tier 兜底——已存在，直接复用。

**仓库约定**：`AgentTransportFactory` 类注释明令「模型名必须来自选中模板，不得硬编码 DeepSeek」；
文案统一走 `userMessage`/`quotaFailureMessage`，不内联裸字符串。

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|---------|---------------------|
| 重新生成工程 | `cd RecapApp && xcodegen generate && sh ../scripts/fix_scheme.sh` | 无报错 |
| iOS 构建+单测 | `xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED |

（模拟器名按本机调整；不新增文件时 xcodegen 一步可跳过，但跑了无害。）

## Scope

**In scope**:
- `RecapApp/Modules/RecapLLM/SuggestedQuestionsGenerator.swift`
- `RecapApp/Modules/RecapUI/AskConversationModel.swift`
- `RecapApp/Modules/RecapLLM/AskMeetingDossier.swift`
- `RecapApp/Modules/RecapUI/MeetingSession.swift`
- `RecapApp/Tests/RecapLLMTests/`（新增一个测试文件）
- `plans/README.md`（状态行）

**Out of scope**:
- `AgentTransportFactory.modelName` 本身（范本，不要改）。
- `RecapCredentialError.userMessage` 的文案措辞（定案，不改）。
- MinutesPipeline / AgentKernel 主链路的模型名（8-02 已修）。
- MeetingSession 中其它 statusMessage（只动列出的两处）。

## Git workflow

- Branch: `advisor/044-model-name-copy-regression`
- Commit style：`fix(app): LLM 旁路模型名统一走 modelName()；凭证失败文案统一走 quotaFailureMessage`。
- 不要 push / 开 PR。

## Steps

### Step 1: 修点 1、2（SuggestedQuestions / rewriteRetrievalQuery）

两处同构：`model: LLMPresets.deepSeekFlash` 改为在 `let provider = …` 附近先解析一次：

```swift
            let provider = try LLMProviderFactory.makeCurrent()
            let model = AgentTransportFactory.modelName(for: LLMSelection.selectedTemplate, role: .quick)
            let stream = provider.streamText(…, model: model, …)
```

`SuggestedQuestionsGenerator.swift` 在 RecapLLM 模块内，`import RecapModels` 已有则不用动 import
（`LLMSelection` 在 RecapModels）。`AskConversationModel.swift` 在 RecapUI，确认文件顶部已有
`import RecapLLM`（同文件已用 AgentTransportFactory 的其它符号则必然有）。

### Step 2: 修点 3（AskModelRouter）

`AskModelRouter.model(for:)` 内部改为委托 `AgentTransportFactory.modelName`（BYOK 时保留
flash/pro 分档语义，云端档自动回落 cred.llmModel）：

```swift
public enum AskModelRouter {
    public static func model(for phase: MeetingPhase) -> String {
        // BYOK DeepSeek 保留会中 flash / 会后 pro 分档;云端档统一网关下发模型(modelName 内处理)。
        if AIServiceMode.current == .byok, LLMSelection.selectedTemplate == .deepseek {
            return phase == .review ? LLMPresets.deepSeekPro : LLMPresets.deepSeekFlash
        }
        return AgentTransportFactory.modelName(for: LLMSelection.selectedTemplate, role: phase == .review ? .deep : .quick)
    }
}
```

注意：BYOK 非 DeepSeek 模板也走 `modelName`（返回 selectedModel ?? defaultModel），这正是期望行为。

### Step 3: 修点 4（转写润色）

`MeetingSession.swift:1534-1543`：模型名在起 Task **前**（MainActor 上下文）解析好，避免在
detached 闭包里读 `AIServiceMode`/`RecapCredentialProvider`：

```swift
            let polishModel = AgentTransportFactory.modelName(for: LLMSelection.selectedTemplate, role: .quick)
            let provider = try await Task.detached(priority: .userInitiated) {
                try LLMProviderFactory.makeDefaultDeepSeek()
            }.value
            let polisher = TranscriptPolisher { system, user in
                provider.streamText(system: system, user: user,
                                     model: polishModel, temperature: 0.1)
            }
            let polished = try await polisher.polish(source)
            meeting.polishedSegmentsData = try? JSONEncoder().encode(polished)
            meeting.polishedModelId = polishModel
```

（`polishedModelId` 一并改为真实使用的模型。）

### Step 4: 修点 5、6（两处文案）

- 点 5（`startProcessing` 免费档强刷 catch）：

```swift
                } catch {
                    self.statusMessage = Self.quotaFailureMessage(error)
                    self.finishReviewWithoutMock()
                }
```

- 点 6（`performRetranscribe` 403 分支）：整个 `catch RecapCredentialError.issueFailed(let status, _) where status == 403`
  分支删除，让它落入下方的通用 `catch`？**不要**——通用 catch 的文案是「重转失败，请检查网络或
  稍后重试」，不区分额度。改为保留该 catch 但委托工具：

```swift
        } catch let error as RecapCredentialError {
            statusMessage = Self.quotaFailureMessage(error)
            return false
        }
```

  （收窄类型到 `RecapCredentialError`，避免吞掉其它错误类型走错文案。）

### Step 5: 回归测试

新建 `RecapApp/Tests/RecapLLMTests/ModelNameRoutingTests.swift`（模仿同目录
`TemplateRecommenderTests.swift` 的 SwiftTesting/XCTest 风格——先看一眼同目录两个文件用的是哪套框架，跟随）：

- 用例 A：`AIServiceMode.current = .freeTrial`（测试内临时设置，teardown 恢复 `.current` 原值；
  注意 `AIServiceMode.current` 是 UserDefaults 持久化的 setter——测试须用例内 save/restore）时，
  `AgentTransportFactory.modelName(for: .glm, role: .quick)` 返回 `LLMPresets.cloudDefaultModel`
  （credential 不可用时回落）——断言**不等于** `LLMPresets.deepSeekFlash`。
- 用例 B：BYOK + `LLMSelection.selectedTemplate = .deepseek`（同样临时设置并恢复）时，
  `AskModelRouter.model(for: .review) == LLMPresets.deepSeekPro`、`.live == LLMPresets.deepSeekFlash`。
- 用例 C（grep 型回归锚点）：读源码文件断言不含 `model: LLMPresets.deepSeekFlash`——
  对 `SuggestedQuestionsGenerator.swift`、`AskConversationModel.swift`、`MeetingSession.swift`
  三个文件文本做包含断言（用 `#filePath` 上溯或把源码路径写死相对 repo root；若取源码路径麻烦，
  此用例可降级为只对 `AskMeetingDossier.swift` 的 `AskModelRouter` 已被用例 B 覆盖，跳过 C 并在
  PR 描述注明）。

**Verify**: `xcodebuild test …` → TEST SUCCEEDED，新文件用例全过。

## Test plan

见 Step 5。核心回归语义：**云端档下任何旁路都拿不到 `deepseek-*` 模型名**。

## Done criteria

- [ ] `grep -rn "model: LLMPresets.deepSeekFlash" RecapApp/Modules` 仅剩
      `AgentTransportFactory.swift` 内的合法定义处（或零命中——`modelName` 函数体里的两处返回值
      写法是 `return LLMPresets.deepSeekFlash`，grep 模式带 `model: ` 前缀所以不会命中它们）
- [ ] `grep -n "免费额度已用完，升级 Pro" RecapApp/Modules/RecapUI/MeetingSession.swift` 零命中
      （`userMessage` 里 RecapCredentialProvider 的定义除外——那是有 tier 分支的正确文案）
- [ ] `xcodebuild test` TEST SUCCEEDED（含新测试）
- [ ] `git status` 无 in-scope 之外改动
- [ ] `plans/README.md` 状态行已更新

## STOP conditions

- `AgentTransportFactory.modelName` 的签名/语义与摘录不符。
- 任一调用点（如 `AskConversationModel.swift:1004` 的 dossier 兜底）结构已变，无法按 Step 描述定位。
- 测试里 `AIServiceMode.current` / `LLMSelection` 的临时修改无法恢复（例如发现它们不可写）——
  停下来报告，不要留下污染其它测试的全局状态。
- 两次修复后构建/测试仍失败。

## Maintenance notes

- 将来新增任何「拿 provider 发一次性请求」的旁路（摘要、标题生成、改写…），模型名必须走
  `AgentTransportFactory.modelName(for:role:)`。Code review 时 grep `LLMPresets.deepSeek` 即可
  快速审计（合法出现点：AgentTransportFactory、AskModelRouter 的 BYOK 分支、LLMPresets 定义处）。
- `meeting.polishedModelId` 现在记录真实模型，若 UI/诊断有按旧值（deepseek-v4-flash）过滤的
  逻辑需注意（审计未发现）。
- 同类但未立项（记录在案）：`MinutesPipelineSmoke`、Agent 免费档路径已在 8-02 修过，无需再动。
