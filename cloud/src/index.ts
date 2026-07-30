import {
  Env,
  DEFAULT_EXPIRE_SECONDS,
  PRO_MONTHLY_QUOTA_SECONDS,
  FREE_ANON_QUOTA_SECONDS,
  FREE_MONTHLY_QUOTA_SECONDS,
  FREE_PER_ISSUE_SECONDS,
} from './env';
import { issueAliyunToken } from './core/aliyun';
import { verifyPro } from './core/prove';
import { verifyFreeApple } from './core/prove-free';
import { landingHTML, privacyHTML, termsHTML, supportHTML } from './core/legal';

// wrangler 须在 main 导出 DO class 才能绑定 QUOTA。
export { QuotaDO } from './adapter/quota-do';

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

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
 * Pro = 实耗覆盖时长计量;免费 = 每次固定扣额。免费档只供 LLM(Flash),ASR 仍端侧。 */
async function handleIssue(req: Request, env: Env): Promise<Response> {
  const user = await verifyPro(req, env);
  if (user.tier === 'none') {
    return Response.json({ error: 'requires_membership' }, { status: 403 });
  }

  const doStub = env.QUOTA.get(env.QUOTA.idFromName(user.userId));

  let limitAnon: number;
  let limitMonthly: number;
  let fixedSecondsParam = '';

  if (user.tier === 'free') {
    // 登录续杯:本次带 identityToken 且验过 → 标记该设备 signedIn(升月度档)
    if (req.headers.get('X-Apple-Identity-Token')) {
      const free = await verifyFreeApple(req, env);
      if (free) {
        await doStub.fetch(`https://quota/elevate?sub=${encodeURIComponent(free.userId)}`);
      }
    }
    limitAnon = FREE_ANON_QUOTA_SECONDS;
    limitMonthly = FREE_MONTHLY_QUOTA_SECONDS;
    fixedSecondsParam = `&seconds=${FREE_PER_ISSUE_SECONDS}`;
  } else {
    // Pro:实耗计量(不传 seconds)
    limitAnon = PRO_MONTHLY_QUOTA_SECONDS;
    limitMonthly = PRO_MONTHLY_QUOTA_SECONDS;
  }

  const quotaRes = await doStub.fetch(
    `https://quota/consume?limitAnon=${limitAnon}&limitMonthly=${limitMonthly}${fixedSecondsParam}`,
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
  });
}
