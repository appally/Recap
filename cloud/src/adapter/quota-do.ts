import { checkQuota, mergeIfSamePeriod, QuotaState, MONTH_MS } from '../core/quota';
import { DEFAULT_EXPIRE_SECONDS, Env } from '../env';

/**
 * per-user 配额计数 Durable Object(按 userId 取实例,强一致无全局瓶颈)。
 * 三套计量:
 *   - 免费 LLM:每次固定扣 `seconds`(映射"N 次纪要");limit 按 signedIn 在 anon/monthly 间选。
 *   - 免费 ASR(国行/端侧不可用兜底):独立 asr 桶,实耗计量;匿名不开放(0),登录后月度。
 *   - Pro(ASR/LLM 共享):不传 `seconds` → 按实耗覆盖时长(上次签发→本次,封顶一个 token 寿命)。
 *
 * 免费档身份锚定(防"重装/换设备刷额度"):
 *   - 未登录:匿名桶 `device:<idfv>`,一次性小额(换设备可重建,成本极小,接受)。
 *   - 首次 Sign-in-with-Apple 验证通过(/elevate):把本设备桶当前月用量迁移并入
 *     `apple:<sub>` 共享桶并记 boundAppleSub;此后 index.ts 经 /probe 把该设备的
 *     所有签发路由到 apple 桶 → 登录用户跨设备/重装共享同一月度额度,匿名用量在
 *     登录时并入冲抵,无法无限续杯。绑定关系存服务端 DO,客户端不可伪造。
 * signedIn 由 /elevate 置位;跨月重置 usedSeconds 但不丢 signedIn/boundAppleSub。
 */
interface StoredQuota extends QuotaState {
  asrUsedSeconds?: number; // ASR 独立桶(免费档兜底)
  asrLastIssueAt?: number;
  lastIssueAt?: number;
  signedIn?: boolean;
  appleSub?: string;
  /** 已绑定 Apple 身份的桶:不再直接消费,index.ts 会路由到 apple:<appleSub> 桶。 */
  boundAppleSub?: string;
}

/** 未绑定:空串;已绑定:apple sub。 */
async function boundAppleSubOf(storage: DurableObjectStorage): Promise<string> {
  const stored = await storage.get<StoredQuota>('quota');
  return stored?.boundAppleSub ?? stored?.appleSub ?? '';
}

export class QuotaDO {
  constructor(private readonly state: DurableObjectState) {}

  // env 参数:跨 DO 迁移需要 QUOTA namespace(同 Worker 绑定,DO 内可用)。
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    // POST /consume?usage=llm|asr&limitAnon=N&limitMonthly=N[&seconds=N] —— 原子扣减
    if (url.pathname === '/consume') {
      const usage = url.searchParams.get('usage') ?? 'llm';
      const limitAnon = Number(url.searchParams.get('limitAnon') ?? '108000');
      const limitMonthly = Number(url.searchParams.get('limitMonthly') ?? String(limitAnon));
      const fixedSecondsRaw = url.searchParams.get('seconds');
      const now = Date.now();
      return this.state.blockConcurrencyWhile(async () => {
        // 已绑定的桶不直接消费:返回 relocated 目标,index.ts 重路由到 apple 桶重试一次。
        const bound = await boundAppleSubOf(this.state.storage);
        if (bound) {
          return Response.json({ allow: false, relocated: `apple:${bound}` }, { status: 409 });
        }
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
          const last = reset ? now : (stored.asrLastIssueAt ?? now - DEFAULT_EXPIRE_SECONDS);
          charge = Math.min(Math.max(now - last, 0), DEFAULT_EXPIRE_SECONDS);
          bucketUsed = asrUsed;
          limit = stored.signedIn ? limitMonthly : limitAnon;
        } else if (fixedSecondsRaw !== null) {
          // 免费档 LLM:固定扣额
          charge = Number(fixedSecondsRaw);
          bucketUsed = llmUsed;
          limit = stored.signedIn ? limitMonthly : limitAnon;
        } else {
          // Pro LLM:实耗(首签按满额扣,不给"每月首张 token 免费"的漏洞)
          const last = reset ? now : (stored.lastIssueAt ?? now - DEFAULT_EXPIRE_SECONDS);
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

    // GET /probe —— 本桶是否已绑定 Apple 身份;已绑定则返回目标共享桶 key。
    if (url.pathname === '/probe') {
      const bound = await boundAppleSubOf(this.state.storage);
      return Response.json({ appleSub: bound || undefined, bound: !!bound });
    }

    // POST /elevate?sub=<appleSub> —— Sign-in-with-Apple 验过后:
    //   把本(设备)桶当前月用量迁移并入 apple:<sub> 共享桶,并记录绑定(幂等)。
    if (url.pathname === '/elevate') {
      const sub = url.searchParams.get('sub') ?? '';
      if (!sub) return Response.json({ error: 'missing_sub' }, { status: 400 });
      return this.state.blockConcurrencyWhile(async () => {
        const stored = (await this.state.storage.get<StoredQuota>('quota')) ?? { usedSeconds: 0, periodStart: 0 };
        if (stored.boundAppleSub === sub) {
          return Response.json({ ok: true }); // 幂等:同身份已绑定
        }
        // 迁移:当前月用量并入 apple 桶(跨月量由 /merge 侧丢弃)。
        const appleDO = env.QUOTA.get(env.QUOTA.idFromName(`apple:${sub}`));
        await appleDO.fetch(
          `https://quota/merge?period=${stored.periodStart}` +
            `&used=${stored.usedSeconds}&asrUsed=${stored.asrUsedSeconds ?? 0}`,
        );
        await this.state.storage.put<StoredQuota>('quota', {
          usedSeconds: 0, // 已并入共享桶,本桶清零(不再直接消费)
          periodStart: stored.periodStart,
          asrUsedSeconds: 0,
          signedIn: true,
          appleSub: sub,
          boundAppleSub: sub,
        });
        return Response.json({ ok: true, migrated: true });
      });
    }

    // POST /merge?period=&used=&asrUsed= —— 供设备桶 /elevate 并入本(apple)桶。
    //   仅当被并入桶与并入量都落在当前 30 天窗口才并入,否则丢弃(跨月数据无价值)。
    if (url.pathname === '/merge') {
      const period = Number(url.searchParams.get('period') ?? '0');
      const used = Number(url.searchParams.get('used') ?? '0');
      const asrUsed = Number(url.searchParams.get('asrUsed') ?? '0');
      return this.state.blockConcurrencyWhile(async () => {
        const now = Date.now();
        const stored = (await this.state.storage.get<StoredQuota>('quota')) ?? { usedSeconds: 0, periodStart: 0 };
        const llmMerge = mergeIfSamePeriod(stored, period, used, now);
        const asrState: QuotaState = {
          usedSeconds: stored.asrUsedSeconds ?? 0,
          periodStart: stored.periodStart,
        };
        const asrMerge = mergeIfSamePeriod(asrState, period, asrUsed, now);
        if (!llmMerge.merged && !asrMerge.merged) {
          return Response.json({ ok: true, merged: 0 }); // 跨月/不同窗口:丢弃
        }
        await this.state.storage.put<StoredQuota>('quota', {
          usedSeconds: llmMerge.next.usedSeconds,
          periodStart: llmMerge.next.periodStart,
          asrUsedSeconds: asrMerge.next.usedSeconds,
          signedIn: stored.signedIn ?? true,
          appleSub: stored.appleSub,
        });
        return Response.json({ ok: true, merged: llmMerge.merged ? used : 0 });
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
