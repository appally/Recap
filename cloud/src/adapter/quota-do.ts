import { checkQuota, QuotaState, MONTH_MS } from '../core/quota';
import { DEFAULT_EXPIRE_SECONDS } from '../env';

/**
 * per-user 配额计数 Durable Object(按 userId 取实例,强一致无全局瓶颈)。
 * 两套计量:
 *   - 免费:每次固定扣 `seconds`(映射"N 次纪要");limit 按 signedIn 在 anon/monthly 间选。
 *   - Pro:不传 `seconds` → 按实耗覆盖时长(上次签发→本次,封顶一个 token 寿命)。
 * signedIn 由 /elevate(Sign-in-with-Apple 验过后)置位;跨月重置 usedSeconds 但不丢 signedIn。
 */
interface StoredQuota extends QuotaState {
  lastIssueAt?: number;
  signedIn?: boolean;
  appleSub?: string;
}

export class QuotaDO {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    // POST /consume?limitAnon=N&limitMonthly=N[&seconds=N] —— 原子扣减
    if (url.pathname === '/consume') {
      const limitAnon = Number(url.searchParams.get('limitAnon') ?? '108000');
      const limitMonthly = Number(url.searchParams.get('limitMonthly') ?? String(limitAnon));
      const fixedSecondsRaw = url.searchParams.get('seconds');
      const now = Date.now();
      return this.state.blockConcurrencyWhile(async () => {
        const stored = (await this.state.storage.get<StoredQuota>('quota')) ?? { usedSeconds: 0, periodStart: 0 };
        const periodStart = now - (now % MONTH_MS);
        const inSamePeriod = stored.periodStart === periodStart;
        const limit = stored.signedIn ? limitMonthly : limitAnon;

        let charge: number;
        if (fixedSecondsRaw !== null) {
          charge = Number(fixedSecondsRaw); // 免费档:固定扣额
        } else {
          const lastIssueAt = inSamePeriod ? stored.lastIssueAt ?? now : now;
          charge = Math.min(Math.max(now - lastIssueAt, 0), DEFAULT_EXPIRE_SECONDS); // Pro:实耗
        }

        const decision = checkQuota(
          { usedSeconds: inSamePeriod ? stored.usedSeconds : 0, periodStart },
          limit,
          now,
          charge,
        );
        if (decision.allow) {
          await this.state.storage.put<StoredQuota>('quota', {
            usedSeconds: decision.nextState.usedSeconds,
            periodStart: decision.nextState.periodStart,
            lastIssueAt: now,
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
        periodStart: stored?.periodStart ?? 0,
        signedIn: stored?.signedIn ?? false,
      });
    }

    return new Response('not found', { status: 404 });
  }
}
