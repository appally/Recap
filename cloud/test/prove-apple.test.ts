import { describe, it, expect } from 'vitest';
import { storekitHostSequence, isProProductId } from '../src/core/prove-apple';

/** 双环境自动覆盖:生产优先 + 404 回落沙盒,上架前后无需手动切 host。 */
describe('storekitHostSequence', () => {
  it('缺省 = 生产优先 + 沙盒殿后(TestFlight/上架都通)', () => {
    const seq = storekitHostSequence(undefined);
    expect(seq[0]).toBe('https://api.storekit.apple.com');
    expect(seq[1]).toBe('https://api.storekit-sandbox.apple.com');
  });

  it('显式钉死沙盒 → 只查沙盒一次(去重,不重复往返)', () => {
    const seq = storekitHostSequence('https://api.storekit-sandbox.apple.com');
    expect(seq).toEqual(['https://api.storekit-sandbox.apple.com']);
  });

  it('带尾斜杠的覆盖值被归一化', () => {
    const seq = storekitHostSequence('https://api.storekit.apple.com/');
    expect(seq[0]).toBe('https://api.storekit.apple.com');
    expect(seq[1]).toBe('https://api.storekit-sandbox.apple.com');
  });
});

describe('isProProductId', () => {
  it('仅白名单 Pro 订阅为真', () => {
    expect(isProProductId('com.liuyong.recap.pro.monthly')).toBe(true);
    expect(isProProductId('com.liuyong.recap.pro.yearly')).toBe(true);
  });
  it('非订阅/其它品误判为假', () => {
    expect(isProProductId('com.liuyong.recap.free')).toBe(false);
    expect(isProProductId('com.liuyong.recap.pro.consumable')).toBe(false);
    expect(isProProductId(undefined)).toBe(false);
  });
});
