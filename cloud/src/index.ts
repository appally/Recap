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

    // POST /v1/account/delete —— 账号删除(App Store 5.1.1(v)):
    // identityToken 验签 → 清 apple:<sub> 共享桶;若带 X-Recap-Device 一并清当前设备桶。
    if (url.pathname === '/v1/account/delete' && req.method === 'POST') {
      return handleAccountDelete(req, env);
    }

    return Response.json({ error: 'not_found' }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;

function html(body: string): Response {
  return new Response(body, { headers: { 'content-type': 'text/html; charset=utf-8' } });
}

/** POST /v1/account/delete:Apple identityToken 验签后清服务端账号数据。
 *  覆盖:apple:<sub> 共享桶(身份+月度用量)与 X-Recap-Device 指定的当前设备桶。
 *  曾绑定该 sub 的其它历史设备桶无法枚举,但其 boundAppleSub 指向的共享桶已清空,
 *  后续 /probe 即回到未登录匿名态,不再持有可用账号数据。 */
async function handleAccountDelete(req: Request, env: Env): Promise<Response> {
  const user = await verifyFreeApple(req, env);
  if (!user) {
    return Response.json({ error: 'unauthorized' }, { status: 401 });
  }
  const wiped: string[] = [];
  await env.QUOTA.get(env.QUOTA.idFromName(`apple:${user.userId}`)).fetch('https://quota/wipe', { method: 'POST' });
  wiped.push(`apple:${user.userId}`);
  const device = req.headers.get('X-Recap-Device');
  if (device) {
    // 设备桶带 sub 做归属校验(DO 内原子完成):仅当该桶绑定的正是本 Apple 账号才清,
    // 防止登录用户定向清他人/匿名设备桶(= 替那台设备重置免费额度)。非本账号桶跳过即可,
    // 账号删除的完整性由上面的 apple 共享桶清除保证。
    const r = await env.QUOTA
      .get(env.QUOTA.idFromName(`device:${device}`))
      .fetch(`https://quota/wipe?sub=${encodeURIComponent(user.userId)}`, { method: 'POST' });
    if (r.ok) wiped.push(`device:${device}`);
  }
  return Response.json({ ok: true, wiped });
}

/** POST /v1/issue:验身份 → 查配额 → 签发阿里临时 token(主 key 在 env secret,永不下发)。
 * Pro = 实耗覆盖时长计量(ASR/LLM 共享 Pro 桶);免费 = LLM 每次固定扣额、ASR 独立月度桶实耗(国行兜底)。
 * 免费档身份锚定:Sign-in 验过后设备配额迁移到 apple:<sub> 共享桶(跨设备/重装统一,防刷),
 * 未登录设备走一次性匿名小桶。用途由 X-Recap-Usage 头(asr|llm)区分,决定免费档扣哪个桶。 */
async function handleIssue(req: Request, env: Env): Promise<Response> {
  const user = await verifyPro(req, env);
  if (user.tier === 'none') {
    return Response.json({ error: 'requires_membership' }, { status: 403 });
  }

  const usage = (req.headers.get('X-Recap-Usage') ?? 'llm').toLowerCase();
  let doStub = env.QUOTA.get(env.QUOTA.idFromName(user.userId));

  let limitAnon: number;
  let limitMonthly: number;
  let fixedSecondsParam = '';

  if (user.tier === 'free') {
    // 登录续杯:本次带 identityToken 且验过 → 把本设备桶用量迁移并入 apple:<sub> 共享桶并绑定
    // (此后该设备所有签发经 /probe 路由到共享桶,跨设备/重装统一限额,防无限续杯)。
    if (req.headers.get('X-Apple-Identity-Token')) {
      const free = await verifyFreeApple(req, env);
      if (free) {
        await doStub.fetch(`https://quota/elevate?sub=${encodeURIComponent(free.userId)}`);
      }
    }
    // 已绑定的设备:配额改从 apple 共享桶计量。
    const probe = (await doStub.fetch('https://quota/probe').then((r) => r.json())) as {
      appleSub?: string;
    };
    if (probe.appleSub) {
      doStub = env.QUOTA.get(env.QUOTA.idFromName(`apple:${probe.appleSub}`));
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

  const consumeURL =
    `https://quota/consume?usage=${usage}&limitAnon=${limitAnon}&limitMonthly=${limitMonthly}${fixedSecondsParam}`;
  // 首次 consume 若命中已绑定设备桶(竞态:probe 与 elevate 交错)会 409 relocated,
  // 重路由到共享桶重试一次(最多一次,防死循环)。
  let quotaRes = await doStub.fetch(consumeURL);
  if (quotaRes.status === 409) {
    const relocated = (await quotaRes.json()) as { relocated?: string };
    if (relocated.relocated) {
      doStub = env.QUOTA.get(env.QUOTA.idFromName(relocated.relocated));
      quotaRes = await doStub.fetch(consumeURL);
    }
  }
  const quota = (await quotaRes.json()) as { allow: boolean; remainingSeconds: number; signedIn?: boolean };
  if (!quota.allow) {
    return Response.json({ error: 'quota_exceeded', remaining_seconds: quota.remainingSeconds }, { status: 403 });
  }

  let token: string;
  try {
    // ASR/LLM 物理隔离:usage=asr 且配置了 ASR 专用 key 时用它签发(白名单仅 ASR 模型),
    // 防止 ASR 桶 token 被用于调用更贵的 LLM/其他模型(阿里临时 token 无独立 scope,继承 key 权限)。
    const masterKey =
      usage === 'asr' && env.DASHSCOPE_ASR_API_KEY ? env.DASHSCOPE_ASR_API_KEY : env.DASHSCOPE_API_KEY;
    token = (await issueAliyunToken(masterKey, DEFAULT_EXPIRE_SECONDS)).token;
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
