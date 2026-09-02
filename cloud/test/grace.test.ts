import { describe, it, expect } from 'vitest';
import { graceActive, PRO_GRACE_WINDOW_MS } from '../src/core/quota';

/** Pro Apple 验证宽限期窗口判定:付费用户体验优先于风控严谨(敞口=仅限曾验证成功的交易)。 */
describe('graceActive', () => {
  const now = 1_700_000_000_000;

  it('无打点(从未验证成功)不放行——伪造者首验即被拒', () => {
    expect(graceActive(undefined, now)).toBe(false);
  });

  it('近期验证过 → 宽限放行', () => {
    expect(graceActive(now - 60_000, now)).toBe(true);
    expect(graceActive(now - PRO_GRACE_WINDOW_MS + 1, now)).toBe(true);
  });

  it('超过 3 天窗口 → 拒(宽限有界)', () => {
    expect(graceActive(now - PRO_GRACE_WINDOW_MS, now)).toBe(false);
    expect(graceActive(now - PRO_GRACE_WINDOW_MS - 1, now)).toBe(false);
  });
});
