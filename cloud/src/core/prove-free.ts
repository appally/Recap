import { jwtVerify, createRemoteJWKSet } from 'jose';
import { Env } from '../env';

/** Apple 公钥(自动缓存、按 kid 轮换重取)。 */
const APPLE_JWKS = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));

/**
 * 验 Sign-in-with-Apple identityToken(RS256 JWT,~10min 有效)。
 * 用途:免费用户「登录续杯」——验一次即把该设备配额升级到月度档(见 index.ts 的 elevate)。
 * aud=原生 iOS Bundle ID(复用 env.APPLE_BUNDLE_ID);无需 .p8(与 Pro 的 App Store Server API 不同)。
 * 失败/缺→null(过期/签名错/密钥轮换/缺 sub)。
 */
export async function verifyFreeApple(req: Request, env: Env): Promise<{ userId: string } | null> {
  const token = req.headers.get('X-Apple-Identity-Token');
  if (!token || !env.APPLE_BUNDLE_ID) return null;
  try {
    const { payload } = await jwtVerify(token, APPLE_JWKS, {
      issuer: 'https://appleid.apple.com',
      audience: env.APPLE_BUNDLE_ID,
    });
    if (!payload.sub) return null;
    return { userId: payload.sub };
  } catch {
    return null;
  }
}
