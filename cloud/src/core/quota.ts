/** 配额纯函数(无副作用,易测)。月度周期:按 30 天窗口对齐。 */

export interface QuotaState {
  usedSeconds: number;
  periodStart: number; // epoch ms
}

export const MONTH_MS = 30 * 24 * 60 * 60 * 1000;

export interface QuotaDecision {
  allow: boolean;
  nextState: QuotaState;
  remainingSeconds: number;
}

/**
 * 判定一次「请求签发 N 秒」是否放行。跨周期自动重置。
 * 原子性由 Durable Object 的 blockConcurrencyWhile 保证,这里只算数。
 */
export function checkQuota(
  state: QuotaState,
  limitSeconds: number,
  now: number,
  requestSeconds: number,
): QuotaDecision {
  const periodStart = now - (now % MONTH_MS);
  const used = state.periodStart === periodStart ? state.usedSeconds : 0;

  if (used + requestSeconds > limitSeconds) {
    return { allow: false, nextState: { usedSeconds: used, periodStart }, remainingSeconds: Math.max(0, limitSeconds - used) };
  }
  const nextUsed = used + requestSeconds;
  return {
    allow: true,
    nextState: { usedSeconds: nextUsed, periodStart },
    remainingSeconds: limitSeconds - nextUsed,
  };
}
