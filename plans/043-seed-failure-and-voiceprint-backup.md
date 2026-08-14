# Plan 043: seed 失败不再藏走健康用户库 + 声纹文件排除 iCloud 备份

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 510a7fa..HEAD -- RecapApp/Modules/RecapPersistence/RecapDataContainer.swift RecapApp/Modules/RecapASR/BackupExclusion.swift RecapApp/Modules/RecapASR/Diarization/VoiceprintGallery.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / security(合规)
- **Planned at**: commit `510a7fa`, 2026-08-14

## Why this matters

两个独立但都属「静默伤用户」的问题：

1. **数据丢失级 bug**：`RecapDataContainer` 把「容器/schema 迁移失败」与「seed 播种抛错」放在
   同一个 do/catch 里。播种（预置 LLM 供应商、DEBUG 示例会议）只是锦上添花——它抛错时，一份
   完全健康、能正常打开的用户库会被 `fallbackAfterFailure` **改名移走**（`Recap.store.failed-<stamp>`），
   本次会话跑空内存库，下次启动新建空库——用户全部会议历史静默消失。

2. **合规红线**：声纹画廊（256 维 speaker embedding + 历史样本，文件头注释自认 PIPL §28 敏感
   生物特征信息）以明文 JSON 存 Application Support，且 `BackupExclusion` 的排除清单没覆盖它
   ——会随 iCloud/iTunes 备份离开设备，与「声纹仅本地存储、不出端」的设计声明矛盾。上架审核
   隐私问卷也按「不出端」口径填写。

## Current state

- `RecapApp/Modules/RecapPersistence/RecapDataContainer.swift:82-97` — 主路径，seed 与迁移失败混在同一 catch：

```swift
        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: RecapMigrationPlan.self,
                configurations: [configuration]
            )
            let seedContext = ModelContext(container)
            try seedIfNeeded(in: seedContext)
            Self.shared = container
            return container
        } catch {
            // schema 不兼容且无法轻量迁移时：绝不静默删库。
            // 旧库改名备份保留（可恢复/排查），降级 inMemory 容器避免真机白屏。
            logger.error("ModelContainer 加载失败，走备份降级：\(error.localizedDescription, privacy: .public)")
            return try fallbackAfterFailure(storeURL: storeURL)
        }
```

- `RecapDataContainer.swift:101-116` — `fallbackAfterFailure` 无条件 `backupStore` 改名 + 降级 inMemory；
  其中 `:113` 也有一句 `try seedIfNeeded(in: seedContext)`（这里失败会直接 throw 出函数）。
- `RecapDataContainer.swift:132-139` — `seedIfNeeded` → `seedDefaultProviderIfNeeded`（fetch/insert/save）+
  DEBUG 下 `seedSampleMeetingsIfNeeded`。
- `RecapApp/Modules/RecapASR/BackupExclusion.swift` — 现有排除项：`excludeMeetingAudio` /
  `excludeHuggingFaceCache` / `excludeFluidAudioModels`。文件头注释明确「排除必须在文件已创建后调用（幂等）」。
- `RecapApp/Modules/RecapASR/Diarization/VoiceprintGallery.swift:24-27` — 文件位置：

```swift
        url = dir.appendingPathComponent("VoiceprintGallery.json")
        load()
```

- `VoiceprintGallery.swift:44` — `public func save(_ evolved: [Speaker])`（写盘点，加排除的挂点）。

**仓库约定**：`BackupExclusion` 的每个公开方法都带一行中文 doc comment 说明排除对象与理由，
失败静默（`try?`）不影响主流程——照抄这个风格。

**设计约束**（来自 BackupExclusion 头注释，必须遵守）：`isExcludedFromBackup` 不会遗传给
之后新建的文件——排除必须**在文件每次写盘后**调用（幂等），不能只在 init 调一次。

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|---------|---------------------|
| iOS 构建+测试 | `cd RecapApp && xcodegen generate && sh ../scripts/fix_scheme.sh && xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO` | TEST SUCCEEDED（全部既有用例通过） |

（模拟器名按本机 `xcrun simctl list devices available` 调整。）

## Scope

**In scope**:
- `RecapApp/Modules/RecapPersistence/RecapDataContainer.swift`
- `RecapApp/Modules/RecapASR/BackupExclusion.swift`
- `RecapApp/Modules/RecapASR/Diarization/VoiceprintGallery.swift`
- `plans/README.md`（状态行）

**Out of scope**:
- 声纹文件的**加密落盘**（CryptoKit/Keychain）——独立后续项，本 plan 只做备份排除（零副作用止血）。
- `fallbackAfterFailure` 的改名/降级机制本身（迁移安全网，是定案）。
- `seedSampleMeetingsIfNeeded` 的内容与 DEBUG 开关。

## Git workflow

- Branch: `advisor/043-seed-failure-voiceprint-backup`
- Commit style：`fix(app): seed 失败不再误伤健康库；声纹文件排除 iCloud 备份`（conventional + 中文，见 `git log`）。
- 不要 push / 开 PR。

## Steps

### Step 1: 主路径把 seed 移出迁移 catch（A4）

改 `RecapDataContainer.swift:82-97` 为：

```swift
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: RecapMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            // schema 不兼容且无法轻量迁移时：绝不静默删库。
            // 旧库改名备份保留（可恢复/排查），降级 inMemory 容器避免真机白屏。
            logger.error("ModelContainer 加载失败，走备份降级：\(error.localizedDescription, privacy: .public)")
            return try fallbackAfterFailure(storeURL: storeURL)
        }
        // seed 失败 ≠ 库坏了：预置供应商/示例会议只是锦上添花，绝不能把健康库拖进备份降级。
        // 记日志、跳过播种，仍返回已加载的持久化容器。
        do {
            let seedContext = ModelContext(container)
            try seedIfNeeded(in: seedContext)
        } catch {
            logger.error("seed 播种失败（跳过，不影响已加载库）：\(error.localizedDescription, privacy: .public)")
        }
        Self.shared = container
        return container
```

**Verify**: 构建命令通过（编译期验证）。

### Step 2: fallbackAfterFailure 内的 seed 也改为不抛出

`fallbackAfterFailure`（`:112-113`）里的

```swift
        let seedContext = ModelContext(container)
        try seedIfNeeded(in: seedContext)
```

包进同样的 do/catch（log + 继续）——降级路径上再抛 seed 错误会把整个 `makeSharedContainer`
炸成启动崩溃，与「降级避免白屏」的意图矛盾。

**Verify**: 构建命令通过。

### Step 3: BackupExclusion 新增声纹排除（A5）

1. `BackupExclusion.swift` 新增方法（放在 `excludeFluidAudioModels` 之后）：

```swift
    /// 声纹画廊（Application Support/VoiceprintGallery.json，speaker embedding 256 维 + 历史样本）。
    /// 声纹属敏感生物特征（PIPL §28），设计承诺「仅本地、不出端」——排除 iCloud/iTunes 备份。
    /// 注意头注释：不遗传，须在每次写盘后调用（幂等）。
    public static func excludeVoiceprintGallery() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        exclude(appSupport.appendingPathComponent("VoiceprintGallery.json"))
    }
```

2. `VoiceprintGallery.swift` 的 `save(_:)` 写盘成功后调用 `BackupExclusion.excludeVoiceprintGallery()`。
   先读 `save` 的现有实现，在文件写入完成的分支后追加调用（放在 `try? fm.write…` 类语句之后、
   无论成功失败都不抛——排除失败本来就静默）。同时在 `init` 的 `load()` 之后也调一次
   （覆盖「文件早已存在但本版本之前从未排除」的老用户，幂等无害）。

**Verify**: 构建命令通过；`grep -n "excludeVoiceprintGallery" RecapApp/Modules -r` → 3 处命中
（定义 + save + init）。

## Test plan

本 plan 的两条路径（seed 抛错、备份排除）缺现成测试基建（in-memory 容器 fixture 属独立测试 plan）。
最低验证门槛：
- 既有全量测试通过（Step 命令），证明无回归。
- 手动核查（写进 PR 描述即可）：DEBUG 下临时在 `seedDefaultProviderIfNeeded` 入口 `throw`
  一次 → 启动后会议列表数据仍在、`Application Support` 下无 `.failed-` 新文件。（跑完记得删掉 throw。）

## Done criteria

- [ ] `RecapDataContainer.swift` 主路径：seed 在独立 do/catch 中，catch 不再触达 `fallbackAfterFailure`
- [ ] `fallbackAfterFailure` 内 seed 失败不抛出
- [ ] `grep -rn "excludeVoiceprintGallery" RecapApp/Modules` ≥ 3 处
- [ ] `xcodebuild test` 全部既有用例通过
- [ ] `git status` 无 in-scope 之外改动
- [ ] `plans/README.md` 状态行已更新

## STOP conditions

- `RecapDataContainer.swift` 与摘录不符（例如迁移计划/seed 结构已被重构）。
- `VoiceprintGallery.save` 的实现不是「写 Application Support 下固定文件名」的形态（比如已改为
  Keychain/加密存储——那本 plan 的 Step 3 作废，报告即可）。
- 构建/测试两次修复后仍失败。

## Maintenance notes

- 「备份排除须在每次写盘后调用」是 BackupExclusion 的通用约束——将来任何新增写盘点（如导出、
  迁移脚本）都要带上。
- 加密落盘（Secure Enclave 包裹 AES-GCM 或 Keychain 大值存储）是明确的后续项，涉及老文件迁移，
  做的时候顺手可以把「排除备份」降级为第二道防线保留。
- seed 失败日志上线后值得在 Analytics/日志里观察频率——`seedDefaultProviderIfNeeded` 的 fetch
  抛错可能暴露其它容器问题。
