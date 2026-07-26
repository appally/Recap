# Plan 010: 建立可一键运行的验证基线（测试 target + 关键纯函数单测）

> **Executor instructions**: Follow step by step; verify; STOP on drift.
> Update `plans/README.md` when done.
>
> **Drift check**: Confirm `RecapApp/project.yml` still has no `unitTest`
> targets and `rg -n "XCTest|@Test" RecapApp` returns no test sources.
> If tests already exist, STOP and extend rather than duplicate.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none（应尽早执行；**008 硬依赖本计划**）
- **Category**: tests
- **Planned at**: workspace snapshot 2026-07-25（无 git SHA）

## Why this matters

RecapApp 无任何 unit test target、无 CI。长会相关改动（截断、检查点、PCM、门闩）只能靠真机偶然发现回归。先建立「一键红绿」与 3–5 条表征测试，后续 008 map-reduce 与其它重构才有安全网。`ReminderDispatchNotes` 注释已写「便于单测」但无测试文件——本计划兑现。

## Current state

- `RecapApp/project.yml` — 仅 Models/ASR/LLM/Persistence/UI/App
- 无 `.github/workflows`
- `ReminderDispatchNotes.swift:3` — 「便于单测」
- `MinutesPipeline.cappedTranscript` — 静态纯函数，易测
- 构建命令见 `RecapApp/README.md`

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Generate | `cd /Users/liuyong/Projects/Recap/RecapApp && xcodegen generate` | exit 0，pbxproj 含测试 target |
| Test | 见 Step 3（destination 按 `xcodebuild -showdestinations` 选可用模拟器） | **TEST SUCCEEDED**，新用例全过 |
| Build app | 现有 Simulator build | BUILD SUCCEEDED |

## Scope

**In scope**:
- `RecapApp/project.yml` — 增加 `RecapModelsTests`、`RecapLLMTests`（必要时 `RecapASRTests`）
- 新建测试源码目录，例如：
  - `RecapApp/Tests/RecapModelsTests/ReminderDispatchNotesTests.swift`
  - `RecapApp/Tests/RecapLLMTests/MinutesPipelineCapTests.swift`
  - `RecapApp/Tests/RecapASRTests/AsrEngineResolverTests.swift`（若 resolver 可在无真实 Speech 下测凭证分支——测不动则跳过 ASR target，只做 Models+LLM）
- 可选：`.github/workflows/ios.yml` — `xcodegen` + build（+ test）；若环境无签名/模拟器，CI 可先只 `xcodegen` + `build CODE_SIGNING_ALLOWED=NO`
- `RecapApp/README.md` — 增加「测试」一节命令
- `plans/README.md` 共用验证命令可指向测试

**Out of scope**:
- UI 测试 / XCUITest
- 真机 CI
- 为 `MeetingSession` 写完整集成测试（需 mock 注入，另案）
- 修改 Bench/Prototype

## Steps

### Step 1: project.yml 增加测试 target

参照 XcodeGen 文档，为 framework 挂 unit test：

```yaml
  RecapModelsTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests/RecapModelsTests
    dependencies:
      - target: RecapModels
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.recap.models.tests
        GENERATE_INFOPLIST_FILE: YES

  RecapLLMTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests/RecapLLMTests
    dependencies:
      - target: RecapLLM
      - target: RecapModels
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.recap.llm.tests
        GENERATE_INFOPLIST_FILE: YES
```

将测试 bundle 挂到 `RecapApp` scheme 的 `testTargets`（XcodeGen `scheme.testTargets` 或 app scheme 段）。若 XcodeGen 语法需调整，以 `xcodegen generate` 成功且 Xcode 能看到测试 target 为准。

**Verify**: `xcodegen generate` exit 0；`rg -n "RecapLLMTests" RecapApp.xcodeproj/project.pbxproj` 有匹配。

### Step 2: 编写表征测试

**ReminderDispatchNotesTests**（XCTest 或 Swift Testing `@Test`，与仓库 Swift 6 一致即可）：

- `make` 含会议名与原文
- `make` 无 evidence 时只有会议名行
- `ekPriority` high/medium/low/nil → 1/5/9/0

**MinutesPipelineCapTests**：

- 短于 maxChars → 恒等
- 长于 maxChars → 含 `中间转写已省略`（**008 落地后改断言**：中段抽样仍被某个 chunk 覆盖；本计划先锁当前行为，008 再改测试）
- 在测试文件顶部注释：`// 008 will replace middle-drop behavior; update assertions then`

可选 **AsrEngineResolver**：仅当能不触发真实 SpeechAnalyzer 下载时测「无凭证时跳过云端」；否则 SKIP。

**Verify**: 测试文件编译进 target。

### Step 3: 跑通 xcodebuild test

```bash
cd /Users/liuyong/Projects/Recap/RecapApp
xcodegen generate
DEST=$(xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -showdestinations 2>/dev/null | \
  grep 'platform:iOS Simulator' | head -1 | sed -n 's/.*id:\([^,}]*\).*/\1/p')
# 若 DEST 空，使用: -destination 'generic/platform=iOS Simulator' 可能不能 test；
# 改用显式 name，如 'platform=iOS Simulator,name=iPhone 16'
xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp \
  -destination "id=$DEST" \
  -only-testing:RecapModelsTests -only-testing:RecapLLMTests \
  CODE_SIGNING_ALLOWED=NO
```

→ `** TEST SUCCEEDED **`

若 scheme 名不同，以 XcodeGen 生成的为准。

### Step 4: README + 可选 CI

README 增加测试命令。可选 GitHub Actions：

```yaml
# macos-15, brew/xcodegen, xcodegen generate, xcodebuild build
```

无 git remote 时可只写 workflow 文件不 push。

**Verify**: README 含 `xcodebuild test`；本地 test 绿。

## Test plan

本计划自身即测试基建。最少 5 个断言用例（notes×3 + cap×2）。

## Done criteria

- [ ] `project.yml` 含至少两个 unit-test target（或 Models+LLM）
- [ ] `xcodebuild test` 对上述 target 成功
- [ ] `ReminderDispatchNotes` 有真实测试（注释承诺兑现）
- [ ] `cappedTranscript` 有表征测试
- [ ] README 有测试说明；本 plan README 行 DONE

## STOP conditions

- XcodeGen 无法把 test bundle 链到 framework（签名/host app）→ 改用 `RecapAppTests` host 为 App target，测 `@testable import RecapLLM`
- 环境无 iOS Simulator runtime → 报告，至少保证 `xcodegen` + app build，测试文件就位

## Maintenance notes

- 008 修改截断行为时**必须**同步改 `MinutesPipelineCapTests`。
- Reviewer：勿在单测里打真实网络；勿读取真实 Keychain 秘钥值写入断言。
- Follow-up：RecordingSession fake engine 集成测试；CI 缓存 DerivedData。
