import { describe, it, expect } from 'vitest';
import { signRelayToken, verifyRelayToken, rewriteRelayModel } from '../src/core/relay';
import { buildIssueResponse } from '../src/index';

/** plan 056 /v1/relay：relay token 签验、model 强制改写、issue 响应 relay_* 字段双向兼容。 */

const SECRET = 'test-hmac-secret-056';

describe('relay token', () => {
  it('签验 round-trip（sub/tier/usage 透传）', async () => {
    const token = await signRelayToken({ userId: 'device:abc', tier: 'free', ttlSeconds: 900, secret: SECRET });
    const payload = await verifyRelayToken(token, SECRET);
    expect(payload?.sub).toBe('device:abc');
    expect(payload?.tier).toBe('free');
    expect(payload?.usage).toBe('llm');
  });

  it('过期 → null', async () => {
    const now = Date.now();
    const token = await signRelayToken({
      userId: 'u',
      tier: 'pro',
      ttlSeconds: 60,
      secret: SECRET,
      nowMs: now - 120_000,
    });
    expect(await verifyRelayToken(token, SECRET, now)).toBeNull();
  });

  it('未过期（边界 exp > now）→ 放行', async () => {
    const now = Date.now();
    const token = await signRelayToken({ userId: 'u', tier: 'pro', ttlSeconds: 60, secret: SECRET, nowMs: now });
    expect((await verifyRelayToken(token, SECRET, now))?.sub).toBe('u');
  });

  it('篡改 body / 换密钥 / 非法输入 → null', async () => {
    const token = await signRelayToken({ userId: 'u', tier: 'pro', ttlSeconds: 60, secret: SECRET });
    const [body, mac] = token.split('.');
    const tampered = (body.startsWith('e') ? 'd' : 'e') + body.slice(1) + '.' + mac;
    expect(await verifyRelayToken(tampered, SECRET)).toBeNull();
    expect(await verifyRelayToken(token, 'wrong-secret')).toBeNull();
    expect(await verifyRelayToken('garbage', SECRET)).toBeNull();
    expect(await verifyRelayToken('onlybody', SECRET)).toBeNull();
  });
});

describe('rewriteRelayModel（托管模型由网关独占决定）', () => {
  it('覆盖客户端 model，其余字段保留', () => {
    const out = rewriteRelayModel('{"model":"whatever","stream":true,"messages":[{"role":"user"}]}', 'auto/glm');
    expect(out).not.toBeNull();
    expect(JSON.parse(out as string)).toEqual({
      model: 'auto/glm',
      stream: true,
      messages: [{ role: 'user' }],
    });
  });

  it('非 JSON / JSON 数组 / 标量 → null（拒绝转发）', () => {
    expect(rewriteRelayModel('not json', 'auto/glm')).toBeNull();
    expect(rewriteRelayModel('[1,2,3]', 'auto/glm')).toBeNull();
    expect(rewriteRelayModel('42', 'auto/glm')).toBeNull();
  });
});

describe('buildIssueResponse relay 字段（新旧客户端双向兼容）', () => {
  const baseEnv = {
    ASR_WSS: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference/',
    LLM_BASE: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    ASR_MODEL: 'paraformer-realtime-v2',
    LLM_MODEL: 'qwen-plus-2025-12-01',
  };
  const baseArgs = {
    token: 'sts-test-token',
    tier: 'free',
    remainingSeconds: 120,
    signedIn: false,
    expiresInSeconds: 900,
  };

  it('未传 relay 凭证 → 不带 relay_* 键（旧形状逐字节不变）', () => {
    const body = buildIssueResponse({ ...baseArgs, env: baseEnv });
    expect(!('relay_token' in body)).toBe(true);
    expect(!('relay_base' in body)).toBe(true);
  });

  it('传入 → relay_token/relay_base 成对携带', () => {
    const body = buildIssueResponse({
      ...baseArgs,
      env: baseEnv,
      relayToken: 'rt.x.y',
      relayBase: 'https://recap.manymind.chat/v1/relay',
    });
    expect(body['relay_token']).toBe('rt.x.y');
    expect(body['relay_base']).toBe('https://recap.manymind.chat/v1/relay');
  });
});
