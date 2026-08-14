# Plan 042: 商业化堵漏包——免费档 TTL 阀门 / 退款检查 / 后台续签 guard / 错误透传 / Host 白名单

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 510a7fa..HEAD -- cloud/src RecapApp/Modules/RecapModels/RecapCredentialProvider.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / security
- **Planned at**: commit `510a7fa`, 2026-08-14

## Why this matters

网关对免费档的配额语义是「每次签发固定扣 120s ≈ 1 次 Flash 纪要」，但签发的阿里临时 token
TTL 对所有档位统一是 1800s——而 chat completions 按请求计费不按时间计费，一张 30 分钟有效
的 token 在有效期内可发起**任意次** LLM 请求。TTL 是网关自己可控的阀门，现在没关。同批修复：
Pro 判定不看 `revocationDate`（退款用户在原 expiresDate 前照常白嫖）、免费档被纳入客户端后台
滚动续签（挂机 ~2 小时烧光 600s 匿名桶）、502 响应把上游错误原文透传给客户端、STOREKIT_HOST
无白名单（配置被污染时整条 Pro 校验被架空且无告警）。

五个修复全部是网关侧小改 + 客户端一行 guard，可一次 deploy 完成。

## Current state

- `cloud/src/env.ts:37` — `export const DEFAULT_EXPIRE_SECONDS = 1800;`（单次签发 30min，客户端滚动续签）
- `cloud/src/env.ts:48` — `export const FREE_PER_ISSUE_SECONDS = 120;`（免费档每次签发固定扣额）
- `cloud/src/index.ts:133-142` — 签发处，所有档位统一 TTL：

```ts
  let token: string;
  try {
    // ASR/LLM 物理隔离:usage=asr 且配置了 ASR 专用 key 时用它签发(白名单仅 ASR 模型),...
    const masterKey =
      usage === 'asr' && env.DASHSCOPE_ASR_API_KEY ? env.DASHSCOPE_ASR_API_KEY : env.DASHSCOPE_API_KEY;
    token = (await issueAliyunToken(masterKey, DEFAULT_EXPIRE_SECONDS)).token;
  } catch (e) {
    return Response.json({ error: 'issue_failed', detail: String(e) }, { status: 502 });
  }
```

- `cloud/src/index.ts:144-148` — 响应里 `expires_in: DEFAULT_EXPIRE_SECONDS`（写死常量）
- `cloud/src/core/prove-apple.ts:60-62` — host 无白名单：

```ts
  const host = (env.APPLE_STOREKIT_HOST ?? DEFAULT_STOREKIT_HOST).replace(/\/$/, '');
  const endpoint = `${host}/v1/transactions/${txnId}`;
```

- `cloud/src/core/prove-apple.ts:81-89` — isPro 判定无 revocationDate：

```ts
  const payload = decodeJwt(jws) as {
    productId?: string;
    expiresDate?: number;
    originalTransactionId?: string;
  };

  const isPro =
    isProProductId(payload.productId) &&
    (payload.expiresDate ?? 0) > Date.now();
```

- `cloud/src/core/aliyun.ts:13` — `issueAliyunToken(key, expireSeconds)` 接口本身支持 1–1800s 任意 TTL
- `cloud/src/core/prove-apple.ts:13` — `const DEFAULT_STOREKIT_HOST = 'https://api.storekit.it.com';`
- 客户端 `RecapApp/Modules/RecapModels/RecapCredentialProvider.swift:149-151` — 后台续签入口：

```swift
    /// 启动后台滚动续签(recapCloud + Pro 时在 app 启动调用)。
    public func startBackgroundRefresh() {
        guard isActiveCloud else { return }
```

- `RecapCredentialProvider.swift:180-184` — guard 实际放行免费档（与上一行注释矛盾）：

```swift
    /// 是否走托管凭证：Pro 会员(recapCloud + pro) 或 免费档(freeTrial)。
    public var isActiveCloud: Bool {
        (AIServiceMode.current == .recapCloud && RecapAccountStore.current.tier == .pro)
            || AIServiceMode.current == .freeTrial
    }
```

- `RecapApp/App/RecapAppApp.swift:53` — 唯一调用点，且位于 `await membership.start()` 之后（tier 已就绪，guard 收紧安全）
- 客户端 `RecapCredentialProvider.swift:93-96` — 续签阈值（与 300s TTL 的交互见 Step 4）：

```swift
    /// 提前续签阈值:剩余 < 5min 即续。
    private let refreshLeadSeconds: TimeInterval = 300
```

**仓库约定**（必须遵守）：
- cloud 侧注释是中文、说明「为什么」的风格，见 `cloud/src/env.ts` 每个常量上的注释——新常量照此写。
- 网关改动部署前有现成验证脚本（`cloud/scripts/verify-sts-llm.mjs` 等），本 plan 不要求跑（需真实 secrets）。
- Swift 侧 `RecapCredentialProvider` 是 `@unchecked Sendable + NSLock`；改 guard 不涉及锁。

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|---------|---------------------|
| Cloud typecheck | `cd cloud && npx tsc --noEmit` | exit 0 |
| Cloud tests | `cd cloud && npx vitest run` | 9+ tests pass（含新增） |
| iOS 构建 | `cd RecapApp && xcodegen generate && sh ../scripts/fix_scheme.sh && xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |

## Scope

**In scope**（只改这些文件）:
- `cloud/src/env.ts`
- `cloud/src/index.ts`
- `cloud/src/core/prove-apple.ts`
- `cloud/test/quota.test.ts`（新增用例；或新建 `cloud/test/prove-apple.test.ts`）
- `RecapApp/Modules/RecapModels/RecapCredentialProvider.swift`
- `plans/README.md`（状态行）

**Out of scope**（不要碰）:
- `cloud/src/adapter/quota-do.ts` — 计量口径问题（首签扣 0）是**独立拍板项**，本 plan 不改。
- `/v1/issue` 限流 / App Attest / JWS 持有证明 — 后续独立 plan。
- `RecapCredentialProvider.ensureFresh` 的其余逻辑、`isActiveCloud` 本身（其它调用方依赖它放行免费档）。

## Git workflow

- Branch: `advisor/042-monetization-plug-pack`
- Commit style: 仓库用 conventional commits 中文描述（见 `git log`：`fix(cloud): LLM 模型统一到网关…`）。建议两个 commit：`fix(cloud): …`（网关侧）与 `fix(app): …`（客户端 guard）。
- 不要 push、不要开 PR、**不要 `wrangler deploy`**（部署由用户在验证后执行）。

## Steps

### Step 1: 免费档 TTL 降到 300s（A1）

1. `cloud/src/env.ts` 新增常量（放在 `FREE_PER_ISSUE_SECONDS` 之后，照同文件注释风格）：

```ts
/** 免费档签发 TTL:token 5min 过期,把"一次签发=无限次请求"的窗口从 30min 压到 5min。
 *  不用 120s:纪要管线(summary+todos+重试)单次可能跑 2-4min,过短会在请求中途过期。 */
export const FREE_TTL_SECONDS = 300;
```

2. `cloud/src/index.ts` 的 `handleIssue`：Pro 分支签发保持 `DEFAULT_EXPIRE_SECONDS`；free 分支签
   `FREE_TTL_SECONDS`。实现方式自选其一，但 `expires_in` 响应字段必须等于**实际签发的 TTL**
   （现在是写死的 `DEFAULT_EXPIRE_SECONDS`，客户端靠它算缓存过期）。建议在 tier 判定处（`if (user.tier === 'free')`）
   同时算好 `const ttlSeconds = user.tier === 'free' ? FREE_TTL_SECONDS : DEFAULT_EXPIRE_SECONDS;`，
   签发与 `expires_in` 都用它。
3. 注意 `usage === 'asr'` 的免费档也用同一 TTL（免费 ASR 桶是实耗计量，token 更短不影响计量总额，
   只增加续签频率；FunASREngine 的段间续签会多签几次，可接受）。

**Verify**: `cd cloud && npx tsc --noEmit` → exit 0。

### Step 2: isPro 增加 revocationDate 检查（A2）

1. `cloud/src/core/prove-apple.ts`：把判定抽成可测纯函数并加退款字段：

```ts
/** Pro 判定纯函数(供单测):productId 属 Pro、未过期、且未被退款/撤销。 */
export function evaluateProStatus(payload: {
  productId?: string;
  expiresDate?: number;
  revocationDate?: number;
}): boolean {
  return (
    isProProductId(payload.productId) &&
    (payload.expiresDate ?? 0) > Date.now() &&
    !payload.revocationDate
  );
}
```

2. `verifyProApple` 里 `decodeJwt` 的类型标注加 `revocationDate?: number;`，`const isPro = evaluateProStatus(payload);`。
   （`expirationReason` 不加——billing retry 期间 Apple 仍算有效，惩罚用户不合适。）
3. 诊断日志（`:92-98` 的 `console.log('[prove-apple] verify', …)`）补一行 `revoked: !!payload.revocationDate,`。

**Verify**: `cd cloud && npx tsc --noEmit` → exit 0。

### Step 3: 502 不透传上游错误原文（C4）+ Host 白名单（C6）

1. `cloud/src/index.ts:140-142` 的 catch 改为：

```ts
  } catch (e) {
    // 上游错误细节只进服务端日志(Workers Logs),客户端只拿稳定错误码——不泄露内部拓扑。
    console.error('[issue] aliyun token failed', { usage, error: String(e) });
    return Response.json({ error: 'issue_failed' }, { status: 502 });
  }
```

2. `cloud/src/core/prove-apple.ts`：在文件常量区加

```ts
/** STOREKIT_HOST 白名单:防 var 误配/被覆写为任意 URL 时,伪造的 signedTransactionInfo 被无条件信任。 */
const ALLOWED_STOREKIT_HOSTS = new Set([
  'https://api.storekit.it.com',
  'https://api.storekit-sandbox.it.com',
]);
```

并在 `verifyProApple` 中 `const host = …` 之后校验：

```ts
  if (!ALLOWED_STOREKIT_HOSTS.has(host)) {
    console.error('[prove-apple] REFUSED non-whitelisted STOREKIT_HOST:', host);
    return { userId: '', isPro: false };
  }
```

**Verify**: `cd cloud && npx tsc --noEmit` → exit 0。

### Step 4: 客户端后台续签只对 Pro 开（A3）

1. `RecapCredentialProvider.swift` 的 `startBackgroundRefresh()`，把 guard 从 `isActiveCloud` 收紧：

```swift
    public func startBackgroundRefresh() {
        // 仅 Pro 滚动续签:免费档按需 ensureFresh 即可(每次 LLM 签发固定扣额,
        // 后台空转会把匿名桶 600s 挂机耗尽)。注释与本行此前不一致——以本行为准。
        guard AIServiceMode.current == .recapCloud, RecapAccountStore.current.tier == .pro else { return }
```

2. 同文件 `ensureFresh`（`:133`）的提前返回条件 `c.expiresAt.timeIntervalSinceNow > refreshLeadSeconds`
   在 TTL=300s 的免费档下永远为假 → 每次调用都会打网关。把 lead 改为与实际 TTL 自适应：

```swift
        let lead = min(refreshLeadSeconds, max(TimeInterval(expiresInGuess) / 2, 30))
```

   其中 `expiresInGuess` 取 `readCache()` 里距过期的时间——最简单实现：先读 `c`，用
   `c.expiresAt.timeIntervalSinceNow` 反推不可行（那是剩余时间不是 TTL）。**采用如下实现**：
   给 `Cached` 不加字段，改为在 `writeCache` 时记录 `cachedTTL: TimeInterval`（`@unchecked Sendable`
   类的普通 var + lock），`ensureFresh` 用 `min(refreshLeadSeconds, max(cachedTTL / 2, 30))`。
   若你觉得有更简单的等价实现（例如直接 `if remaining > ttl/2`），可以用，但必须保证：免费档
   TTL=300s 时两次 `ensureFresh()` 间隔 < 150s 不触发第二次网关请求。

3. 免费档 LIVE 云端 ASR 依赖段间续签（FunASREngine），TTL 变短后它在段边界 `ensureFresh(force:)`——
   force 路径不受 lead 影响，无需改动。**不要**改 FunASREngine。

**Verify**: iOS 构建命令 → BUILD SUCCEEDED。

### Step 5: 新增单测

在 `cloud/test/` 新建 `prove-apple.test.ts`（模仿 `cloud/test/quota.test.ts` 的 import 与 describe 风格）：

- `evaluateProStatus`：Pro productId + 未来 expiresDate + 无 revocationDate → true
- 同上 + `revocationDate: Date.now() - 1000`（已退款）→ **false**（本 plan 的回归锚点）
- 非 Pro productId → false；已过期 → false

在 `cloud/test/quota.test.ts` 追加（若已有同名 describe 就并入）：

- env 常量一致性：`FREE_TTL_SECONDS < DEFAULT_EXPIRE_SECONDS` 且 `FREE_TTL_SECONDS >= 120`

**Verify**: `cd cloud && npx vitest run` → 全部通过（9 个旧 + 4 个新）。

## Test plan

见 Step 5。结构性参照 `cloud/test/quota.test.ts`（纯函数 import + describe/it，无 mock 框架）。
`verifyProApple` 本身依赖 Request/env/fetch，不在本 plan 测（引入 vitest-pool-workers 是独立 plan）。

## Done criteria

- [ ] `cd cloud && npx tsc --noEmit` exit 0
- [ ] `cd cloud && npx vitest run` 全过，含 4 个新用例
- [ ] `grep -n "detail: String(e)" cloud/src/index.ts` 无结果
- [ ] `grep -n "FREE_TTL_SECONDS" cloud/src/env.ts cloud/src/index.ts` 两处均有
- [ ] `grep -n "revocationDate" cloud/src/core/prove-apple.ts` 有结果
- [ ] `grep -n "ALLOWED_STOREKIT_HOSTS" cloud/src/core/prove-apple.ts` 有结果
- [ ] `RecapCredentialProvider.swift` 的 `startBackgroundRefresh` guard 含 `tier == .pro`
- [ ] iOS 构建 BUILD SUCCEEDED
- [ ] `git status` 无 in-scope 之外的改动
- [ ] `plans/README.md` 状态行已更新

## STOP conditions

- `index.ts` 的签发段与「Current state」摘录不符（例如已有人改过分档 TTL）。
- Step 4 的 lead 自适应改动需要触碰 `FunASREngine.swift` 或 `ensureFresh` 之外的调用方才能编译通过。
- 免费档某条路径（如 `MeetingSession.startProcessing` 免费档强刷）在 TTL 300s 下出现语义依赖
  （例如有代码假设 token 至少 25min 有效）——发现即停，报告具体位置。
- vitest 新用例两次修复后仍失败。

## Maintenance notes

- 部署顺序：网关先 deploy、客户端后发版。旧客户端（TTL 1800s 期望）拿到 300s 的 `expires_in`
  会按实际值算过期，行为正确，只是续签更频繁。
- `FREE_TTL_SECONDS` 若将来调整，Step 4 的 lead 自适应自动跟随，无需同步改。
- 退款用户在被 `evaluateProStatus` 拒绝后会看到「Pro 凭证签发被拒，请确认订阅有效后重试」
  （客户端 `RecapCredentialError.userMessage` 对 `requires_membership` 的文案）。
- 明确不在本 plan：QuotaDO 首签扣 0 的口径（待产品拍板）、/v1/issue 限流、JWS 持有证明。
