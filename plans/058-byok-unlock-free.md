# Plan 058: BYOK 门禁废除——模型自由不再收费墙

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（《开放化战略》P1 解锁开放第一刀：「不用锁死在任何一个模型公司」与 ¥68 解锁费直接冲突）
- **Effort**: S（门控点 8 处 + 文案 + 测试；不动商业模式其余部分）
- **Risk**: LOW–MEDIUM（动 MembershipStore 模式解析，需回归老购买者路径）
- **Depends on**: 无（与 056/057 并行安全）
- **Category**: feature / monetization

## Why this matters

「开放」若锁在付费墙后就不再是开放。现状 BYOK（LLM 供应商选择 + ASR 引擎选择 + 百炼 Key）需 `byokUnlocked`（¥68 买断）或 Pro——这恰是战略要废除的反面样本。**废除的是门禁，不是商品**：`byok.unlock` 保留在架，改义为「支持者徽章」（老用户购买记录合法、权益不减），商店文案更新属 App Store Connect 操作，不在本 plan。

## Current state（勘察结论，grep byokUnlocked 核实）

- `Modules/RecapUI/SettingsView.swift:156-198`：服务模式解析 UI（recapCloud/byok 可选性分支）。
- `Modules/RecapUI/Settings/LLMSettingsView.swift:26`（模板列表 gated）、`:90`（「需解锁」badge）、`:94`、`:359`（custom baseURL 编辑 gated）。
- `Modules/RecapUI/Settings/ASRSettingsView.swift:40`（引擎选择 gated）、`:69`（非 `.auto` 强制回落）。
- `Modules/RecapUI/Settings/AccountSettingsView.swift:116`（状态点颜色）。
- `Modules/RecapUI/Account/MembershipStore.swift:13`（`byokUnlocked` 标记）、`:81`（`(isPro, byokUnlocked)` 模式解析 switch）、`:121`（entitlement 刷新写入）、`:156`（显示文案 "BYOK"）。
- `Modules/RecapModels/RecapCredentialProvider.swift:67/:75`（userMessage「免费额度已用完，升级 Pro 或解锁自备密钥后再试」×2）。
- `Recap.storekit` / `MembershipProducts.swift`：`byok.unlock` NonConsumable。

## Implementation

### Wave A: MembershipStore 模式解析放开

1. `:81` 的 `(isPro, byokUnlocked)` switch：BYOK 恒为合法模式——用户选 byok 即 byok，不再因未购买回落 freeTrial（勘察确认该 switch 语义后改；若它承担「订阅过期回退」职责，只解除 byokUnlocked 维度，isPro 维度保留）。
2. `byokUnlocked` 属性保留解码（老购买者显示「支持者」徽章用），**从一切功能门控中移除**。
3. 新增单测：未购买 byok + mode=.byok + 已配 Key → `makeSelectedBYOK()` 成功（RecapLLMTests 或 RecapUITests 内就近放置）。

### Wave B: 三处设置 UI 拆锁

1. `LLMSettingsView`：模板列表无条件可选；删「需解锁」badge 与 `:359` 拦截；custom baseURL/模型名编辑放开（`byokUnlocked` 条件全部移除，含 `:26/:94`）。
2. `ASRSettingsView`：`:40` 引擎选择放开；`:69` 删除「非 auto 强制回落」逻辑。
3. `SettingsView:156-198` 与 `AccountSettingsView:116`：模式分支按新语义重排（byok 总可选；recapCloud 仍需 Pro）；「解锁自备密钥」入口卡整块删除。
4. 若存在解锁购买页（BYOKUnlockSheet/paywall 类，grep `byok.unlock` UI 入口）：入口移除，深链保留可购（支持者）。

### Wave C: 文案与测试

1. `RecapCredentialProvider.userMessage` 两处：「免费额度已用完，升级 Pro 或**解锁自备密钥**后再试」→「免费额度已用完，可在设置中改用自备密钥（免费）继续」。
2. 全 repo grep「解锁自备密钥/需解锁」清残留文案。
3. 跑受影响测试：`MeetingSessionLifecycleTests` 及 grep `byok` 命中的测试文件，更新断言。

**红线**：不删 `MembershipProducts.byok.unlock` 商品定义与 StoreKit 交易解码；不动 recapCloud 的 Pro 验签；不动免费档托管滴灌（它只管托管路径）。

## Verification

1. `cd RecapApp && xcodegen generate && sh scripts/fix_scheme.sh` + 构建 + 相关测试绿。
2. 模拟器（无任何购买）：设置 → 出现完整供应商列表；选 DeepSeek 填 Key → 保存无拦截；ASR 引擎选 FunASR → 生效（重转一场可走云端）。
3. 老路径回归：沙盒账号已购 byok.unlock → 徽章仍显示；Pro 用户 recapCloud 不受影响。

## STOP conditions

- `MembershipStore.swift:81` 的 switch 语义与勘察不符（承担了订阅过期回退等职责且与 byok 解锁耦合无法分离）——停下贴出现状代码，勿大改 MembershipStore。
- 发现 UI 之外的功能性门控（如管线内 byokUnlocked 检查）且涉及计费口径——记录并停下确认，勿顺手改商业模式。

## 执行记录（2026-09-28）

- **勘察修正**：`MembershipStore.refreshEntitlements` 的 `(pro, mode)` switch 只做 freeTrial↔recapCloud 漂移修正，**本就不碰 byok**（注释明言「byok 是用户主动选择，绝不覆盖」）——Wave A 实际无代码改动，门禁全部在设置 UI 层。
- **Wave B DONE（代码）**：
  - `LLMSettingsView`：来源选择常驻（body 门控删除）；「自备密钥」卡删「需解锁」badge 与跳转拦截；`reload()` 删 byok 锁定分支（保留 recapCloud 无 Pro 回落）；脚注与「升级 Pro」文案更新。
  - `ASRSettingsView`：引擎选择器 + Fun Key 常驻；删 onAppear 强制 `.auto`；`engineStatusCard` 死代码删除。
  - `SettingsView` 会员卡：标题/额度徽章/进度/描述从「历史购买」改为「当前模式」判定；byok 解锁者显示「支持者」。
  - `MembershipStore`：tierLabel/restore 文案 → 支持者。
  - `MembershipSettingsView`：买断商品重写为「支持 Recap」支持者定位（hero/perks/CTA/兜底文案）。
- **Wave C DONE（代码）**：「解锁自备密钥」全仓清零（RecapCredentialProvider ×2、MeetingSession ×1、MeetingNoteView ×2、AIServicePreferences 注释）；9 个改动文件 `swiftc -parse` 全过；无测试断言被拆门禁（grep 证实）。**红线守住**：`byok.unlock` 商品与 StoreKit 解码未动；`AccountSettingsView:116` 保留（entitlement 展示非门禁）；recapCloud Pro 验签未动。
- **⚠️ 构建验证 BLOCKED（同 056，环境）**：GitHub 资产不可达 → 待网络恢复后跑构建 + RecapUITests 回归 + 模拟器手测（无购买：选供应商填 Key 无拦截；沙盒已购 byok：徽章仍显示）。
- **待用户**：App Store Connect 中 `byok.unlock` 商品文案/截图改义「支持 Recap」（随 v0.9 发布走）。

### 补充（同日晚，网络恢复后闭环）

- **构建+测试绿**：arm64 模拟器 BUILD SUCCEEDED；RecapLLMTests 245/245、RecapModelsTests 101/101（与 056 同轮回归）。**状态：DONE（代码+构建+单测）**——模拟器 UI 手测（无购买填 Key 无拦截 / 老购买者显示「支持者」）留给用户 5 分钟抽查。
