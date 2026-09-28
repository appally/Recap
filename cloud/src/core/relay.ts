/** /v1/relay 短期 HMAC relay token（plan 056）。
 *  客户端持它经网关代理访问中转，真实中转 Key 只存 Workers secret（开源红线：Key 出二进制）。
 *  与 /v1/issue 的阿里临时 token 同一信任模型：TTL 与签发一致（免费档 LLM 15min 封顶），
 *  TTL 内不限次——敞口与既有 aliyun token 相同，计量口径仍按 /v1/issue。 */

export interface RelayTokenPayload {
  sub: string;
  tier: string;
  usage: 'llm';
  /** 过期时刻（Unix 秒，含于签名体）。 */
  exp: number;
  iat: number;
}

const te = new TextEncoder();

function b64url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromB64url(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', te.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'sign',
    'verify',
  ]);
}

export async function signRelayToken(args: {
  userId: string;
  tier: string;
  ttlSeconds: number;
  secret: string;
  /** 可注入时钟（测试）。 */
  nowMs?: number;
}): Promise<string> {
  const iat = Math.floor((args.nowMs ?? Date.now()) / 1000);
  const payload: RelayTokenPayload = {
    sub: args.userId,
    tier: args.tier,
    usage: 'llm',
    exp: iat + args.ttlSeconds,
    iat,
  };
  const body = b64url(te.encode(JSON.stringify(payload)));
  const key = await hmacKey(args.secret);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, te.encode(body)));
  return `${body}.${b64url(mac)}`;
}

/** 验签 + 过期 + usage 检查；任何不合法返回 null（401 由调用方统一回）。 */
export async function verifyRelayToken(
  token: string,
  secret: string,
  nowMs?: number,
): Promise<RelayTokenPayload | null> {
  const dot = token.indexOf('.');
  if (dot <= 0 || dot === token.length - 1) return null;
  const body = token.slice(0, dot);
  const mac = token.slice(dot + 1);
  let bodyBytes: Uint8Array;
  let macBytes: Uint8Array;
  try {
    bodyBytes = fromB64url(body);
    macBytes = fromB64url(mac);
  } catch {
    return null;
  }
  const key = await hmacKey(secret);
  const ok = await crypto.subtle.verify('HMAC', key, macBytes, te.encode(body));
  if (!ok) return null;
  let payload: RelayTokenPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(bodyBytes));
  } catch {
    return null;
  }
  if (payload.usage !== 'llm') return null;
  const now = Math.floor((nowMs ?? Date.now()) / 1000);
  if (typeof payload.exp !== 'number' || payload.exp <= now) return null;
  return payload;
}

/** 上游 body 的 model 强制改写（纯函数，供 vitest）：托管模型由网关独占决定，客户端不可选。
 *  非 JSON / JSON 数组 / 标量 → null（拒绝转发，400）。 */
export function rewriteRelayModel(rawBody: string, model: string): string | null {
  try {
    const parsed = JSON.parse(rawBody);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;
    parsed.model = model;
    return JSON.stringify(parsed);
  } catch {
    return null;
  }
}
