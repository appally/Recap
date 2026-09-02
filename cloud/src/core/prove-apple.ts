import { SignJWT, importPKCS8, decodeJwt } from 'jose';
import { Env } from '../env';

/** Pro 订阅产品 ID(须与客户端 MembershipProducts 及 Recap.storekit 一致)。 */
const PRO_PRODUCT_IDS = new Set(['com.liuyong.recap.pro.monthly', 'com.liuyong.recap.pro.yearly']);

/** 判定 productId 是否为 Pro 订阅(替代宽松的 includes('pro'),避免未来含 'pro' 字样的非订阅品误判)。 */
export function isProProductId(id?: string): boolean {
  return !!id && PRO_PRODUCT_IDS.has(id);
}

/**
 * App Store Server API 官方主机(2021-09 起生产即用 api.storekit.apple.com;旧 api.storekit.it.com 已弃用,
 * 从 Cloudflare Workers 出口实测不可达)。沙盒交易(TestFlight/提审)只在沙盒 host 可查。
 * 验证策略:生产优先 → 404(TransactionIdNotFoundError)回落沙盒,上架前后无需手动切 host。
 */
const PRODUCTION_STOREKIT_HOST = 'https://api.storekit.apple.com';
const SANDBOX_STOREKIT_HOST = 'https://api.storekit-sandbox.apple.com';

/** Pro 判定内存缓存(5min TTL,省 Apple 查询;per-isolate,冷启动失效可接受)。 */
const PRO_CACHE_TTL_MS = 5 * 60 * 1000;
const proCache = new Map<string, { userId: string; isPro: boolean; exp: number }>();

/** 候选 host 序列:显式 APPLE_STOREKIT_HOST(可选覆盖生产)在前,沙盒殿后;去重防重复查同一 host。缺省 = [生产, 沙盒] 自动双环境。纯函数供 vitest。 */
export function storekitHostSequence(override?: string): string[] {
  const primary = (override ?? PRODUCTION_STOREKIT_HOST).replace(/\/$/, '');
  return primary === SANDBOX_STOREKIT_HOST ? [primary] : [primary, SANDBOX_STOREKIT_HOST];
}

/** 单次 getTransactionInfo 查询结果(供双环境回落)。 */
type StorekitQuery =
  | { kind: 'ok'; userId: string; isPro: boolean }
  | { kind: 'not_found' }
  | { kind: 'error'; status: number; body: string };

/**
 * 生产验证:App Store Server API —— Get Transaction Info。
 *
 * 客户端传 StoreKit2 的 Transaction.id(头 X-Apple-Transaction-Id)。
 * 后端用 .p8 签 ES256 JWT 调 Apple,信任 HTTPS 响应来源,解码 signedTransactionInfo
 * 判 productId 属 Pro 且未过期。
 *
 * ⚠️ 需真实 .p8 + keyId + issuerId + bundleId 配进 Secrets 后,用沙盒/真机调通。
 *    防伪造:查的是 Apple 权威账本,伪造的 transactionId 查不到 / 查到非 Pro。
 */
export async function verifyProApple(req: Request, env: Env): Promise<{ userId: string; isPro: boolean }> {
  const txnId = req.headers.get('X-Apple-Transaction-Id');
  const keyPem = env.APPLE_PRIVATE_KEY;
  const keyId = env.APPLE_KEY_ID;
  if (!txnId || !keyPem || !keyId || !env.APPLE_ISSUER_ID || !env.APPLE_BUNDLE_ID) {
    // 诊断:区分「请求未带 txnId」与「服务端 secrets 未配全」——两者都静默 isPro=false,此前无法分辨。
    console.log('[prove-apple] missing auth/secrets', {
      hasTxn: !!txnId, hasKey: !!keyPem, hasKeyId: !!keyId,
      hasIssuer: !!env.APPLE_ISSUER_ID, hasBundle: !!env.APPLE_BUNDLE_ID,
    });
    return { userId: '', isPro: false };
  }

  // 卫生拦截:合成/占位交易 ID(Xcode 本地 StoreKit 测试产物,如 "0";真 Apple 交易为 ≥10 位数字)。
  // 提前拒掉省一次注定 4xx/5xx 的 Apple 往返,且日志不再与真实验证失败混淆。
  if (!/^\d{10,}$/.test(txnId)) {
    console.log('[prove-apple] invalid txnId format (local StoreKit test data?)', { txnId });
    return { userId: '', isPro: false };
  }

  // 命中缓存(5min 内)直接返回,省 Apple App Store Server API 往返。
  const cached = proCache.get(txnId);
  if (cached && cached.exp > Date.now()) {
    console.log('[prove-apple] cache hit', { isPro: cached.isPro });
    return { userId: cached.userId, isPro: cached.isPro };
  }

  const ecKey = await importPKCS8(keyPem, 'ES256');
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId, typ: 'JWT' })
    .setIssuer(env.APPLE_ISSUER_ID)
    .setIssuedAt()
    .setExpirationTime('5m')
    .setAudience('appstoreconnect-it-v1')
    .setSubject(env.APPLE_BUNDLE_ID)
    .setJti(crypto.randomUUID())
    .sign(ecKey);

  // 候选 host 序列:显式 APPLE_STOREKIT_HOST(可选覆盖生产)在前,沙盒殿后;
  // 去重防「显式设成沙盒」时对同一 host 查两次。缺省 = [生产, 沙盒] 自动双环境。
  const hosts = storekitHostSequence(env.APPLE_STOREKIT_HOST);

  // 生产优先 → 仅「交易不存在(404/4040010)」才回落沙盒;硬错误(401/5xx/host 不可达)不透传沙盒,
  // 避免把配置/网关故障误判成「订阅无效」(那类失败由 index.ts 的宽限期兜底付费体验)。
  for (const host of hosts) {
    const r = await queryStorekitTransaction(jwt, host, txnId);
    if (r.kind === 'not_found') {
      console.log('[prove-apple] txn not in this environment, try next host', { host, txnId });
      continue;
    }
    if (r.kind === 'error') {
      return { userId: '', isPro: false };
    }
    proCache.set(txnId, { ...r, exp: Date.now() + PRO_CACHE_TTL_MS });
    if (proCache.size > 2000) proCache.clear(); // 防无界增长
    return { userId: r.userId, isPro: r.isPro };
  }

  console.log('[prove-apple] txn not found in any environment', { txnId, hosts });
  return { userId: '', isPro: false };
}

/** 单 host 查询 Get Transaction Info;404/4040010 → not_found,其余失败 → error(带诊断日志)。 */
async function queryStorekitTransaction(jwt: string, host: string, txnId: string): Promise<StorekitQuery> {
  const endpoint = `${host}/inApps/v1/transactions/${txnId}`;
  const res = await fetch(endpoint, { headers: { Authorization: `Bearer ${jwt}` } });

  if (res.status === 404) {
    // 4040010 TransactionIdNotFoundError:交易不在该环境(生产查沙盒交易/沙盒查生产交易都走这)。
    return { kind: 'not_found' };
  }
  if (!res.ok) {
    // 诊断核心盲点:.p8 四元组错或已 revoke → 401;5xx/不可达 → host 级故障。
    // 打 status+host+body 一锤定音(定位后可降级日志)。
    const errBody = await res.text().catch(() => '');
    console.log('[prove-apple] Apple API non-ok', {
      status: res.status, host, txnId,
      errBody: errBody.slice(0, 200),
      // 530/1016:host 级故障(Apple 域名从 Cloudflare Workers 出口解析失败)——非我方配置问题。
      hint: res.status >= 520 ? 'host-level failure (Apple host from Workers unreachable)' : undefined,
    });
    return { kind: 'error', status: res.status, body: errBody };
  }

  const body = (await res.json()) as { data?: { signedTransactionInfo?: string } };
  const jws = body.data?.signedTransactionInfo;
  if (!jws) {
    console.log('[prove-apple] no signedTransactionInfo in response', { txnId });
    return { kind: 'error', status: res.status, body: 'missing signedTransactionInfo' };
  }

  const payload = decodeJwt(jws) as {
    productId?: string;
    expiresDate?: number;
    originalTransactionId?: string;
  };

  const isPro =
    isProProductId(payload.productId) &&
    (payload.expiresDate ?? 0) > Date.now();

  // 诊断:productId 不在白名单 / expiresDate 已过,都能从此处看清(此前全静默 isPro=false)。
  console.log('[prove-apple] verify', {
    host, productId: payload.productId,
    expiresDate: payload.expiresDate,
    now: Date.now(),
    expired: (payload.expiresDate ?? 0) <= Date.now(),
    isPro,
  });

  return { kind: 'ok', userId: payload.originalTransactionId ?? txnId, isPro };
}
