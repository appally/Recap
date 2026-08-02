import { checkQuota, QuotaState, MONTH_MS } from '../core/quota';
import { DEFAULT_EXPIRE_SECONDS } from '../env';

/**
 * per-user 配额计数 Durable Object(按 userId 取实例,强一致无全局瓶颈)。
 * 三套计量:
 *   - 免费 LLM:每次固定扣 `seconds`(映射"N 次纪要");limit 按 signedIn 在 anon/monthly 间选。
 *   - 免费 ASR(国行/端侧不可用兜底):独立 asr 桶,实耗计量;匿名不开放(0),登录后月度。
 *   - Pro(ASR/LLM 共享):不传 `seconds` → 按实耗覆盖时长(上次签发→本次,封顶一个 token 寿命)。
 * signedIn 由 /elevate(Sign-in-with-Apple 验过后)置位;跨月重置 usedSeconds 但不丢 signedIn。
 */
interface StoredQuota extends QuotaState {
  asrUsedSeconds?: number; // ASR 独立桶(免费档兜底)
  asrLastIssueAt?: number;
  lastIssueAt?: number;
  signedIn?: boolean;
  appleSub?: string;
}

export class QuotaDO {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    // POST /consume?usage=llm|asr&limitAnon=N&limitMonthly=N[&seconds=N] —— 原子扣减
    if (url.pathname === '/consume') {
      const usage = url.searchParams.get('usage') ?? 'llm';
      const limitAnon = Number(url.searchParams.get('limitAnon') ?? '108000');
      const limitMonthly = Number(url.searchParams.get('limitMonthly') ?? String(limitAnon));
      const fixedSecondsRaw = url.searchParams.get('seconds');
      const now = Date.now();
      return this.state.blockConcurrencyWhile(async () => {
        const stored = (await this.state.storage.get<StoredQuota>('quota')) ?? { usedSeconds: 0, periodStart: 0 };
        const periodStart = now - (now % MONTH_MS);
        const reset = stored.periodStart !== periodStart;
        const isAsr = usage === 'asr';

        const llmUsed = reset ? 0 : stored.usedSeconds;
        const asrUsed = reset ? 0 : (stored.asrUsedSeconds ?? 0);

        let charge: number;
        let bucketUsed: number;
        let limit: number;

        if (isAsr) {
          // ASR 独立桶:实耗计量(封顶一个 token 寿命),与 LLM 桶隔离
          const last = reset ? now : (stored.asrLastIssueAt ?? now);
          charge = Math.min(Math.max(now - last, 0), DEFAULT_EXPIRE_SECONDS);
          bucketUsed = asrUsed;
          limit = stored.signedIn ? limitMonthly : limitAnon;
        } else if (fixedSecondsRaw !== null) {
          // 免费档 LLM:固定扣额
          charge = Number(fixedSecondsRaw);
          bucketUsed = llmUsed;
          limit = stored.signedIn ? limitMonthly : limitAnon;
        } else {
          // Pro LLM:实耗
          const last = reset ? now : (stored.lastIssueAt ?? now);
          charge = Math.min(Math.max(now - last, 0), DEFAULT_EXPIRE_SECONDS);
          bucketUsed = llmUsed;
          limit = limitMonthly;
        }

        const decision = checkQuota({ usedSeconds: bucketUsed, periodStart }, limit, now, charge);

        if (decision.allow) {
          await this.state.storage.put<StoredQuota>('quota', {
            usedSeconds: isAsr ? llmUsed : decision.nextState.usedSeconds,
            periodStart,
            lastIssueAt: isAsr ? stored.lastIssueAt : now,
            asrUsedSeconds: isAsr ? decision.nextState.usedSeconds : asrUsed,
            asrLastIssueAt: isAsr ? now : stored.asrLastIssueAt,
            signedIn: stored.signedIn,
            appleSub: stored.appleSub,
          });
        }
        return Response.json({
          allow: decision.allow,
          remainingSeconds: decision.remainingSeconds,
          signedIn: stored.signedIn ?? false,
        });
      });
    }

    // POST /elevate?sub=<appleSub> —— Sign-in-with-Apple 验过后升级月度档
    if (url.pathname === '/elevate') {
      const sub = url.searchParams.get('sub') ?? '';
      return this.state.blockConcurrencyWhile(async () => {
        const stored = (await this.state.storage.get<StoredQuota>('quota')) ?? { usedSeconds: 0, periodStart: 0 };
        await this.state.storage.put<StoredQuota>('quota', {
          usedSeconds: stored.usedSeconds,
          periodStart: stored.periodStart,
          lastIssueAt: stored.lastIssueAt,
          asrUsedSeconds: stored.asrUsedSeconds,
          asrLastIssueAt: stored.asrLastIssueAt,
          signedIn: true,
          appleSub: sub || stored.appleSub,
        });
        return Response.json({ ok: true });
      });
    }

    // GET /status —— 查询当前用量(供客户端展示「本月剩余」)
    if (url.pathname === '/status') {
      const stored = await this.state.storage.get<StoredQuota>('quota');
      return Response.json({
        usedSeconds: stored?.usedSeconds ?? 0,
        asrUsedSeconds: stored?.asrUsedSeconds ?? 0,
        periodStart: stored?.periodStart ?? 0,
        signedIn: stored?.signedIn ?? false,
      });
    }

    return new Response('not found', { status: 404 });
  }
}
