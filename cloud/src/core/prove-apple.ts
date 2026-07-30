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
    return { userId: '', isPro: false };
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
  if (!res.ok) return { userId: '', isPro: false };

  const body = (await res.json()) as { data?: { signedTransactionInfo?: string } };
  const jws = body.data?.signedTransactionInfo;
  if (!jws) return { userId: '', isPro: false };

  const payload = decodeJwt(jws) as {
    productId?: string;
    expiresDate?: number;
    originalTransactionId?: string;
  };

  const isPro =
    isProProductId(payload.productId) &&
    (payload.expiresDate ?? 0) > Date.now();

  return { userId: payload.originalTransactionId ?? txnId, isPro };
}
