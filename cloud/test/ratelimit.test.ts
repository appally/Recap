import { describe, it, expect } from 'vitest';
import { emptyIpRateLimitState, ipRateLimitDecision, isPlausibleDeviceId } from '../src/core/ratelimit';

/** 入口风控纯函数(2026-09-02 审计 F1):device id 卫生 + per-IP 签发限流决策。 */

describe('isPlausibleDeviceId', () => {
  it('接受 IDFV/UUID 形态(带/不带动连字符,大小写)', () => {
    expect(isPlausibleDeviceId('8C7A9B3D-1E2F-4A5B-9C0D-112233445566')).toBe(true);
    expect(isPlausibleDeviceId('8c7a9b3d1e2f4a5b9c0d112233445566')).toBe(true);
  });

  it('拒绝垃圾串/脚本常用假 ID', () => {
    expect(isPlausibleDeviceId('test-1')).toBe(false);
    expect(isPlausibleDeviceId('device-abc')).toBe(false);
    expect(isPlausibleDeviceId('')).toBe(false);
    expect(isPlausibleDeviceId('x'.repeat(200))).toBe(false);
    expect(isPlausibleDeviceId('脚本刷量')).toBe(false);
  });
});

describe('ipRateLimitDecision', () => {
  const HOUR = 60 * 60 * 1000;
  const base = { max: 240, maxDevices: 40, windowMs: HOUR, now: 1_000_000 };

  it('空状态首次放行并计入', () => {
    const d = ipRateLimitDecision(emptyIpRateLimitState(), { ...base, device: 'aaaabbbbccccdddd' });
    expect(d.allow).toBe(true);
    expect(d.next.count).toBe(1);
    expect(d.next.devices.size).toBe(1);
  });

  it('同 device 重复签发不增加 device 计数(滚动续签场景)', () => {
    let s = emptyIpRateLimitState();
    for (let i = 0; i < 10; i++) {
      s = ipRateLimitDecision(s, { ...base, device: 'aaaabbbbccccdddd' }).next;
    }
    expect(s.count).toBe(10);
    expect(s.devices.size).toBe(1);
  });

  it('超 max 次/h → 拒绝(count),且拒绝不改变状态', () => {
    let s = emptyIpRateLimitState();
    s = { windowStart: base.now, count: 240, devices: new Set(['aaaabbbbccccdddd']) };
    const d = ipRateLimitDecision(s, { ...base, device: 'aaaabbbbccccdddd' });
    expect(d.allow).toBe(false);
    expect(d.reason).toBe('count');
    expect(d.next.count).toBe(240);
  });

  it('换 device 铸桶:超 maxDevices 个新 ID → 拒绝(devices)——防刷核心', () => {
    const devices = Array.from({ length: 40 }, (_, i) => `dev${String(i).padStart(12, '0')}`.replace(/[^0-9a-f]/g, '0'));
    let s = emptyIpRateLimitState();
    for (const d of devices) {
      s = ipRateLimitDecision(s, { ...base, device: d, max: 10_000 }).next;
    }
    expect(s.devices.size).toBe(40);
    const d = ipRateLimitDecision(s, { ...base, device: 'ffff0000ffff0000', max: 10_000 });
    expect(d.allow).toBe(false);
    expect(d.reason).toBe('devices');
  });

  it('窗口过期整体重置(次小时再来是新窗口)', () => {
    const s = { windowStart: base.now, count: 240, devices: new Set(['aaaabbbbccccdddd']) };
    const d = ipRateLimitDecision(s, { ...base, now: base.now + HOUR + 1, device: 'aaaabbbbccccdddd' });
    expect(d.allow).toBe(true);
    expect(d.next.count).toBe(1);
    expect(d.next.devices.size).toBe(1);
  });

  it('无 device 头(Pro 走 txn 验证)只计数不限设备', () => {
    let s = emptyIpRateLimitState();
    for (let i = 0; i < 50; i++) {
      s = ipRateLimitDecision(s, { ...base, device: '' }).next;
    }
    expect(s.count).toBe(50);
    expect(s.devices.size).toBe(0);
  });
});
