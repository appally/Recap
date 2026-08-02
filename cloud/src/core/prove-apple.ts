import { SignJWT, importPKCS8, decodeJwt } from 'jose';
import { Env } from '../env';

/** Pro 订阅产品 ID(须与客户端 MembershipProducts 及 Recap.storekit 一致)。 */
const PRO_PRODUCT_IDS = new Set(['com.liuyong.recap.pro.monthly', 'com.liuyong.recap.pro.yearly']);

/** 判定 productId 是否为 Pro 订阅(替代宽松的 includes('pro'),避免未来含 'pro' 字样的非订阅品误判)。 */
export function isProProductId(id?: string): boolean {
  return !!id && PRO_PRODUCT_IDS.has(id);
}

/** App Store Server API 生产主机(沙盒见 env.APPLE_STOREKIT_HOST)。 */
const DEFAULT_STOREKIT_HOST = 'https://api.storekit.it.com';

/** Pro 判定内存缓存(5min TTL,省 Apple 查询;per-isolate,冷启动失效可接受)。 */
const PRO_CACHE_TTL_MS = 5 * 60 * 1000;
const proCache = new Map<string, { userId: string; isPro: boolean; exp: number }>();

/**
 * 生产验证:App Store Server API v1 —— getTransactionInfo。
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

  const host = (env.APPLE_STOREKIT_HOST ?? DEFAULT_STOREKIT_HOST).replace(/\/$/, '');
  const endpoint = `${host}/v1/transactions/${txnId}`;
  const res = await fetch(endpoint, { headers: { Authorization: `Bearer ${jwt}` } });
  if (!res.ok) {
    // 诊断核心盲点:host=生产(api.storekit.it.com) 查不到沙盒/TestFlight 交易 → 404;
    // .p8 四元组错或已 revoke → 401。打 status+host+body 一锤定音(定位后可降级日志)。
    const errBody = await res.text().catch(() => '');
    console.log('[prove-apple] Apple API non-ok', {
      status: res.status, host, txnId,
      errBody: errBody.slice(0, 200),
    });
    return { userId: '', isPro: false };
  }

  const body = (await res.json()) as { data?: { signedTransactionInfo?: string } };
  const jws = body.data?.signedTransactionInfo;
  if (!jws) {
    console.log('[prove-apple] no signedTransactionInfo in response', { txnId });
    return { userId: '', isPro: false };
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
    productId: payload.productId,
    expiresDate: payload.expiresDate,
    now: Date.now(),
    expired: (payload.expiresDate ?? 0) <= Date.now(),
    isPro,
  });

  const result = { userId: payload.originalTransactionId ?? txnId, isPro };
  proCache.set(txnId, { ...result, exp: Date.now() + PRO_CACHE_TTL_MS });
  if (proCache.size > 2000) proCache.clear(); // 防无界增长
  return result;
}
