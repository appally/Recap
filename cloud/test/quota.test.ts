import { describe, it, expect } from 'vitest';
import { checkQuota, elapsedChargeSeconds, mergeIfSamePeriod, MONTH_MS } from '../src/core/quota';

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

describe('elapsedChargeSeconds — 实耗扣额(回归:ms 当 s 用,2s 续签被扣满 1800 拒签)', () => {
  const now = 1_700_000_000_000;

  it('跨周期首签不扣额(「首签0」容忍)', () => {
    expect(elapsedChargeSeconds(undefined, true, now)).toBe(0);
    expect(elapsedChargeSeconds(now - 5 * 60 * 1000, true, now)).toBe(0);
  });

  it('短间隔续签按实际秒数扣:2s 间隔扣 2s(曾误扣满 1800s)', () => {
    expect(elapsedChargeSeconds(now - 2_000, false, now)).toBe(2);
  });

  it('长间隔封顶一个 token 寿命(1800s)', () => {
    expect(elapsedChargeSeconds(now - 40 * 60 * 1000, false, now)).toBe(1800);
  });

  it('旧记录无时间戳:按满额 1800s 计(从紧)', () => {
    expect(elapsedChargeSeconds(undefined, false, now)).toBe(1800);
  });

  it('回归场景:免费 ASR 匿名桶(300s)首签后 2s 续签应放行', () => {
    // 首签:reset=true,charge=0
    const first = checkQuota({ usedSeconds: 0, periodStart: now - (now % MONTH_MS) }, 300, now, elapsedChargeSeconds(undefined, true, now));
    expect(first.allow).toBe(true);
    expect(first.remainingSeconds).toBe(300);
    // 2s 后段间续签:charge=2,而非旧 bug 的 1800
    const second = checkQuota(first.nextState, 300, now, elapsedChargeSeconds(now - 2_000, false, now));
    expect(second.allow).toBe(true);
    expect(second.remainingSeconds).toBe(298);
  });
});

describe('mergeIfSamePeriod — 设备桶用量并入 apple 共享桶', () => {
  const now = 1_700_000_000_000;
  const currentPeriod = now - (now % MONTH_MS);

  it('同月并入:用量累加', () => {
    const target = { usedSeconds: 600, periodStart: currentPeriod };
    const r = mergeIfSamePeriod(target, currentPeriod, 240, now);
    expect(r.merged).toBe(true);
    expect(r.next.usedSeconds).toBe(840);
  });

  it('被并入桶已跨月(periodStart 旧):目标桶用量按当前周期为 0 时仍可并入新量', () => {
    // 设备桶上月用满、本月还没用过 → 迁移量 0 才合理;此处验证跨月桶迁移量被丢弃
    const oldPeriod = currentPeriod - MONTH_MS;
    const target = { usedSeconds: 0, periodStart: currentPeriod };
    const r = mergeIfSamePeriod(target, oldPeriod, 600, now);
    expect(r.merged).toBe(false);
    expect(r.next.usedSeconds).toBe(0);
  });

  it('目标桶跨月(未重置):先并入到当前周期(0)再累加', () => {
    // 目标桶 periodStart 还是上月(上月 108000 满) → 并入量应只按当前周期计
    const oldPeriod = currentPeriod - MONTH_MS;
    const target = { usedSeconds: 108000, periodStart: oldPeriod };
    const r = mergeIfSamePeriod(target, currentPeriod, 240, now);
    expect(r.merged).toBe(true);
    expect(r.next.usedSeconds).toBe(240);
  });

  it('并入量为 0:同月并入为幂等 no-op', () => {
    const target = { usedSeconds: 300, periodStart: currentPeriod };
    const r = mergeIfSamePeriod(target, currentPeriod, 0, now);
    expect(r.merged).toBe(true);
    expect(r.next.usedSeconds).toBe(300);
  });
});

