import { describe, it, expect } from 'vitest';
import { checkQuota, MONTH_MS } from '../src/core/quota';

describe('checkQuota', () => {
  const limit = 108000; // 30h/月

  it('requestSeconds=0 不增加用量,放行', () => {
    const now = 1_700_000_000_000;
    const periodStart = now - (now % MONTH_MS);
    const d = checkQuota({ usedSeconds: 0, periodStart }, limit, now, 0);
    expect(d.allow).toBe(true);
    expect(d.nextState.usedSeconds).toBe(0);
    expect(d.remainingSeconds).toBe(limit);
  });

  it('限额内累加放行并返回剩余', () => {
    const now = 1_700_000_000_000;
    const periodStart = now - (now % MONTH_MS);
    const d = checkQuota({ usedSeconds: 1000, periodStart }, limit, now, 500);
    expect(d.allow).toBe(true);
    expect(d.nextState.usedSeconds).toBe(1500);
    expect(d.remainingSeconds).toBe(limit - 1500);
  });

  it('超限拒签:状态不变,返回当前剩余', () => {
    const now = 1_700_000_000_000;
    const periodStart = now - (now % MONTH_MS);
    const d = checkQuota({ usedSeconds: limit - 100, periodStart }, limit, now, 200);
    expect(d.allow).toBe(false);
    expect(d.nextState.usedSeconds).toBe(limit - 100);
    expect(d.remainingSeconds).toBe(100);
  });

  it('跨月(periodStart 不同)自动重置用量', () => {
    const oldPeriod = 1_700_000_000_000 - (1_700_000_000_000 % MONTH_MS);
    const now = oldPeriod + MONTH_MS + 5000; // 进入下一周期
    const d = checkQuota({ usedSeconds: limit, periodStart: oldPeriod }, limit, now, 3000);
    expect(d.allow).toBe(true);
    expect(d.nextState.usedSeconds).toBe(3000);
    expect(d.nextState.periodStart).toBe(now - (now % MONTH_MS));
  });
});

describe('checkQuota — 免费档固定扣额(FREE_PER_ISSUE=120)', () => {
  const perIssue = 120;
  const anonLimit = 600; // FREE_ANON: 5 次

  it('5 次固定扣额刚好耗尽匿名桶,第 6 次拒', () => {
    const now = 1_700_000_000_000;
    const periodStart = now - (now % MONTH_MS);
    let state = { usedSeconds: 0, periodStart };
    for (let i = 0; i < 5; i++) {
      const d = checkQuota(state, anonLimit, now, perIssue);
      expect(d.allow).toBe(true);
      state = d.nextState;
    }
    expect(state.usedSeconds).toBe(600);
    // 第 6 次超限
    const over = checkQuota(state, anonLimit, now, perIssue);
    expect(over.allow).toBe(false);
    expect(over.remainingSeconds).toBe(0);
  });
});

