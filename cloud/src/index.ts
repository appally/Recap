import {
  Env,
  DEFAULT_EXPIRE_SECONDS,
  PRO_MONTHLY_QUOTA_SECONDS,
  FREE_ANON_QUOTA_SECONDS,
  FREE_MONTHLY_QUOTA_SECONDS,
  FREE_PER_ISSUE_SECONDS,
  FREE_ANON_ASR_SECONDS,
  FREE_MONTHLY_ASR_SECONDS,
} from './env';
import { issueAliyunToken } from './core/aliyun';
import { verifyPro } from './core/prove';
import { verifyFreeApple } from './core/prove-free';
import { landingHTML, privacyHTML, termsHTML, supportHTML } from './core/legal';
import { ICON_PNG_BASE64 } from './core/icon';

// wrangler 须在 main 导出 DO class 才能绑定 QUOTA。
export { QuotaDO } from './adapter/quota-do';

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    if (url.pathname === '/icon.png' || url.pathname === '/favicon.ico') {
      const binaryStr = atob(ICON_PNG_BASE64);
      const len = binaryStr.length;
      const bytes = new Uint8Array(len);
      for (let i = 0; i < len; i++) {
        bytes[i] = binaryStr.charCodeAt(i);
      }
      return new Response(bytes, {
        headers: {
          'content-type': 'image/png',
          'cache-control': 'public, max-age=86400',
        },
      });
    }

    if (url.pathname === '/') {
      return html(landingHTML());
    }

    if (url.pathname === '/health') {
      return Response.json({ ok: true, service: 'recap-cloud', domain: 'recap.manymind.chat' });
    }

    // 法务静态页(App Store 上架必需:隐私政策 / 使用条款 / 支持)
    if (req.method === 'GET') {
      if (url.pathname === '/privacy') return html(privacyHTML());
      if (url.pathname === '/terms') return html(termsHTML());
      if (url.pathname === '/support') return html(supportHTML());
    }

    // POST /v1/issue —— 签发阿里短期 token(MVP:验权益 → 签发;配额 Phase 2 加 DO)
    if (url.pathname === '/v1/issue' && req.method === 'POST') {
      return handleIssue(req, env);
    }

    return Response.json({ error: 'not_found' }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;

function html(body: string): Response {
  return new Response(body, { headers: { 'content-type': 'text/html; charset=utf-8' } });
}

/** POST /v1/issue:验身份 → 查配额 → 签发阿里临时 token(主 key 在 env secret,永不下发)。
 * Pro = 实耗覆盖时长计量(ASR/LLM 共享 Pro 桶);免费 = LLM 每次固定扣额、ASR 独立月度桶实耗(国行兜底)。
 * 用途由 X-Recap-Usage 头(asr|llm)区分,决定免费档扣哪个桶。 */
async function handleIssue(req: Request, env: Env): Promise<Response> {
  const user = await verifyPro(req, env);
  if (user.tier === 'none') {
    return Response.json({ error: 'requires_membership' }, { status: 403 });
  }

  const usage = (req.headers.get('X-Recap-Usage') ?? 'llm').toLowerCase();
  const doStub = env.QUOTA.get(env.QUOTA.idFromName(user.userId));

  let limitAnon: number;
  let limitMonthly: number;
  let fixedSecondsParam = '';

  if (user.tier === 'free') {
    // 登录续杯:本次带 identityToken 且验过 → 标记该设备 signedIn(升月度档,ASR/LLM 均适用)
    if (req.headers.get('X-Apple-Identity-Token')) {
      const free = await verifyFreeApple(req, env);
      if (free) {
        await doStub.fetch(`https://quota/elevate?sub=${encodeURIComponent(free.userId)}`);
      }
    }
    if (usage === 'asr') {
      // 免费档 ASR 兜底:独立月度桶(登录后 30min/月,匿名 0 不开放),实耗计量(不传 seconds)
      limitAnon = FREE_ANON_ASR_SECONDS;
      limitMonthly = FREE_MONTHLY_ASR_SECONDS;
    } else {
      // 免费档 LLM:固定扣额
      limitAnon = FREE_ANON_QUOTA_SECONDS;
      limitMonthly = FREE_MONTHLY_QUOTA_SECONDS;
      fixedSecondsParam = `&seconds=${FREE_PER_ISSUE_SECONDS}`;
    }
  } else {
    // Pro:ASR/LLM 共享 Pro 桶,实耗计量(不传 seconds)
    limitAnon = PRO_MONTHLY_QUOTA_SECONDS;
    limitMonthly = PRO_MONTHLY_QUOTA_SECONDS;
  }

  const quotaRes = await doStub.fetch(
    `https://quota/consume?usage=${usage}&limitAnon=${limitAnon}&limitMonthly=${limitMonthly}${fixedSecondsParam}`,
  );
  const quota = (await quotaRes.json()) as { allow: boolean; remainingSeconds: number; signedIn?: boolean };
  if (!quota.allow) {
    return Response.json({ error: 'quota_exceeded', remaining_seconds: quota.remainingSeconds }, { status: 403 });
  }

  let token: string;
  try {
    token = (await issueAliyunToken(env.DASHSCOPE_API_KEY, DEFAULT_EXPIRE_SECONDS)).token;
  } catch (e) {
    return Response.json({ error: 'issue_failed', detail: String(e) }, { status: 502 });
  }

  return Response.json({
    dashscope_token: token,
    expires_in: DEFAULT_EXPIRE_SECONDS,
    asr_wss: env.ASR_WSS,
    llm_base: env.LLM_BASE,
    remaining_seconds: quota.remainingSeconds,
    tier: user.tier,
    signed_in: quota.signedIn ?? false,
    asr_model: env.ASR_MODEL,
    llm_model: env.LLM_MODEL,
  });
}
