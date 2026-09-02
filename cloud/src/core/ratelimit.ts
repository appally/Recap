/** /v1/issue 的入口风控纯函数(供 vitest):device id 卫生 + per-IP 签发限流决策。
 *
 *  背景(2026-09-02 审计 F1):免费档身份锚定 X-Recap-Device,此前任意字符串即得
 *  匿名桶且零限流——脚本循环换 device id 即可无限铸造免费桶(每 ID ≈ 5×30min
 *  qwen-plus 无限调窗 + 1×30min ASR 实跑),主 key 账单上界完全取决于百炼白名单
 *  与阿里 QPS。双层防线:
 *    ① device id 卫生:客户端真实来源是 IDFV(UUIDv4,32 hex ± 连字符)。
 *       抬高脚本成本(不能再拿 "test-1"/随机词当桶名),同时防垃圾串变成 DO 名。
 *    ② per-IP 限流:单 IP 每窗口签发次数上限 + 「不同 device id 数」上限——
 *      换 ID 刷桶的特征是同 IP 大量新 device,正好像素级区别于 NAT 后的真人。
 *  常量偏宽(240 次/h、40 设备/h):NAT 大办公室不误伤,而刷量脚本动辄数千次/h。 */

/** 客户端设备标识 plausible 校验:去连字符后为 8–64 位 hex(UUID/IDFV 均满足)。 */
export function isPlausibleDeviceId(value: string): boolean {
  const compact = value.replace(/-/g, '');
  return /^[0-9a-fA-F]{8,64}$/.test(compact);
}

/** per-IP 限流窗口状态(DO 内存态,纯函数决策便于测试;DO 重启即重置,尽力而为)。 */
export interface IpRateLimitState {
  windowStart: number;
  count: number;
  devices: Set<string>;
}

export function emptyIpRateLimitState(): IpRateLimitState {
  return { windowStart: 0, count: 0, devices: new Set() };
}

export interface IpRateLimitParams {
  max: number;
  maxDevices: number;
  windowMs: number;
  device: string;
  now: number;
}

export interface IpRateLimitDecision {
  allow: boolean;
  reason?: 'count' | 'devices';
  count: number;
  deviceCount: number;
  /** 决策后的状态(allow 时已计入;deny 时原样返回便于幂等)。 */
  next: IpRateLimitState;
}

/** 固定窗口计数 + 新 device 去重集合;窗口过期整体重置。 */
export function ipRateLimitDecision(
  state: IpRateLimitState,
  params: IpRateLimitParams,
): IpRateLimitDecision {
  let s = state;
  if (params.now - s.windowStart > params.windowMs) {
    s = { windowStart: params.now, count: 0, devices: new Set() };
  }
  const isNewDevice = params.device !== '' && !s.devices.has(params.device);
  if (s.count >= params.max) {
    return { allow: false, reason: 'count', count: s.count, deviceCount: s.devices.size, next: s };
  }
  if (isNewDevice && s.devices.size >= params.maxDevices) {
    return { allow: false, reason: 'devices', count: s.count, deviceCount: s.devices.size, next: s };
  }
  const next: IpRateLimitState = {
    windowStart: s.windowStart,
    count: s.count + 1,
    devices: new Set(s.devices),
  };
  if (params.device !== '') next.devices.add(params.device);
  return { allow: true, count: next.count, deviceCount: next.devices.size, next };
}
