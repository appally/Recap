/** 阿里 DashScope 临时 API Key 签发(主 key 仅存后端 Secret,客户端只拿临时 token)。 */
const TOKEN_ENDPOINT = 'https://dashscope.aliyuncs.com/api/v1/tokens';

export interface IssuedToken {
  token: string;
  expiresIn: number;
}

/**
 * 用主 key 换取短期临时 token(st- 前缀,有效期 1–1800s)。
 * 字段名兼容 token / api_key(不同文档版本)。
 */
export async function issueAliyunToken(masterKey: string, expireSeconds = 1800): Promise<IssuedToken> {
  const res = await fetch(`${TOKEN_ENDPOINT}?expire_in_seconds=${expireSeconds}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${masterKey}` },
  });
  if (!res.ok) {
    const detail = await res.text();
    throw new Error(`aliyun token issue failed: HTTP ${res.status} ${detail.slice(0, 200)}`);
  }
  const body: unknown = await res.json();
  const obj = body as Record<string, unknown>;
  const data = (obj.data ?? {}) as Record<string, unknown>;
  const token = (obj.token ?? obj.api_key ?? data.token ?? data.api_key) as string | undefined;
  if (!token || typeof token !== 'string') {
    throw new Error(`aliyun token: unexpected response shape: ${JSON.stringify(body).slice(0, 200)}`);
  }
  return { token, expiresIn: expireSeconds };
}
