import { describe, it, expect } from 'vitest';
import { isDevHostName } from '../src/core/prove';

/** ALLOW_STUB 硬护栏的主机判定:localhost 族 + 私网 IPv4 放行(真机连 wrangler dev 局网联调),
 *  生产域名绝不能命中——防误注入导致付费绕过。 */
describe('isDevHostName', () => {
  it('localhost 族放行', () => {
    expect(isDevHostName('localhost')).toBe(true);
    expect(isDevHostName('127.0.0.1')).toBe(true);
    expect(isDevHostName('foo.localhost')).toBe(true);
    expect(isDevHostName('my.test')).toBe(true);
    expect(isDevHostName('macbook.local')).toBe(true);
  });

  it('私网 IPv4 放行(真机连 wrangler dev --ip 0.0.0.0)', () => {
    expect(isDevHostName('192.168.1.5')).toBe(true);
    expect(isDevHostName('10.0.0.8')).toBe(true);
    expect(isDevHostName('172.16.0.1')).toBe(true);
    expect(isDevHostName('172.31.255.255')).toBe(true);
  });

  it('生产域名/公网 IP 一律拒绝(硬护栏)', () => {
    expect(isDevHostName('recap.manymind.chat')).toBe(false);
    expect(isDevHostName('8.8.8.8')).toBe(false);
    expect(isDevHostName('172.32.0.1')).toBe(false);   // 172.32 超出 RFC1918
    expect(isDevHostName('localhost.evil.com')).toBe(false);
  });
});
