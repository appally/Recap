import { verifyProApple } from './prove-apple';
import { Env } from '../env';

export type ProveTier = 'pro' | 'free' | 'none';

export interface ProvedUser {
  userId: string;
  tier: ProveTier;
}

/** ALLOW_STUB 认可的开发主机:localhost 族 + 私网 IPv4(RFC1918/127)。
 *  私网放行让真机能连 Mac 局网 IP 上的 `wrangler dev` 做本地联调(模拟器走 127.0.0.1 本就放行);
 *  生产域名(recap.manymind.chat)不可能是私网 IP,硬护栏语义不变。纯函数供 vitest。 */
export function isDevHostName(host: string): boolean {
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.test') || host.endsWith('.local')) {
    return true;
  }
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const a = Number(m[1]), b = Number(m[2]);
  return a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31);
}

/**
 * 验证请求方身份,返回 tier + userId(配额 DO key)。分流:
 *   - X-Apple-Transaction-Id → verifyProApple(App Store Server API)→ pro / none
 *   - X-Recap-Device(设备 IDFV)→ free,userId='device:<idfv>'(Sign-in 升级由 index.ts 经 verifyFreeApple 单独处理)
 *   - ALLOW_STUB=1 → stub(仅 Xcode 本地 StoreKit 测试,绝不在生产)
 *   - 否则 → none
 */
export async function verifyPro(req: Request, env: Env): Promise<ProvedUser> {
  // 1. Pro 收据
  if (req.headers.get('X-Apple-Transaction-Id')) {
    const hasAppleSecrets = !!(
      env.APPLE_PRIVATE_KEY && env.APPLE_KEY_ID && env.APPLE_ISSUER_ID && env.APPLE_BUNDLE_ID
    );
    if (hasAppleSecrets) {
      const r = await verifyProApple(req, env);
      if (r.isPro) return { userId: r.userId, tier: 'pro' };
    }
    return { userId: '', tier: 'none' };
  }

  // 2. 免费:设备 IDFV
  const device = req.headers.get('X-Recap-Device');
  if (device) return { userId: 'device:' + device, tier: 'free' };

  // 3. stub(仅 dev)
  // 硬护栏:生产域名(hostname 非 localhost/私网)拒绝 ALLOW_STUB=1,防误以 secret 注入导致付费绕过。
  if (env.ALLOW_STUB === '1') {
    const host = new URL(req.url).hostname;
    const isDevHost = isDevHostName(host);
    if (!isDevHost) {
      console.error('[prove] REFUSED ALLOW_STUB=1 on non-dev host:', host);
      return { userId: '', tier: 'none' };
    }
    console.warn('[prove] ALLOW_STUB=1 on dev host:', host);
    const stubPro = (req.headers.get('X-Recap-Pro') ?? '1') === '1';
    return {
      userId: req.headers.get('X-Recap-User') ?? 'dev-user',
      tier: stubPro ? 'pro' : 'none',
    };
  }

  return { userId: '', tier: 'none' };
}
