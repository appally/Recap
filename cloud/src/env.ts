/** Worker 运行时绑定与配置(凭证签发器 + per-user 配额 DO + 法务页)。 */
export interface Env {
  // Secrets(`wrangler secret put` 注入)
  /** 阿里百炼主 key —— RAM 最小权限子账号,仅开 fun-asr-realtime(+指定 qwen)。永不下发客户端。 */
  DASHSCOPE_API_KEY: string;
  /** App Store Connect .p8 + 元数据:Pro 权益服务端真校验(App Store Server API)。 */
  APPLE_PRIVATE_KEY?: string;
  APPLE_KEY_ID?: string;
  APPLE_ISSUER_ID?: string;
  APPLE_BUNDLE_ID?: string;

  // vars(非敏感配置)
  ASR_WSS: string;
  LLM_BASE: string;
  /** App Store Server API 主机。生产默认 https://api.storekit.it.com;TestFlight 沙盒用 https://api.storekit-sandbox.it.com。 */
  APPLE_STOREKIT_HOST?: string;
  /** 仅本地 .dev.vars 用:'1' 时回退信任 X-Recap-* 头的 stub(Xcode 本地 StoreKit 测试不经 Apple 服务器)。绝不在生产开启。 */
  ALLOW_STUB?: string;

  // Durable Object 绑定(Workers Free plan 即可用)
  /** per-user 月度配额计数 DO(按 userId 取实例)。 */
  QUOTA: DurableObjectNamespace;
}

export const DEFAULT_EXPIRE_SECONDS = 1800; // 单次签发 30min,客户端滚动续签

/** Pro 订阅月度配额:按 token 覆盖时长计,30h/月(网关不见音频,只能按 token 有效期计量,是真实音频成本的上界)。 */
export const PRO_MONTHLY_QUOTA_SECONDS = 30 * 60 * 60; // 108000

// 免费体验档配额(均按"每次固定扣额"计,映射 N 次 Flash 纪要;可调):
/** 匿名(未 Sign-in)一次性 ≈ 5 次纪要。 */
export const FREE_ANON_QUOTA_SECONDS = 600;
/** Sign-in-with-Apple 后月度 ≈ 15 次/月。 */
export const FREE_MONTHLY_QUOTA_SECONDS = 1800;
/** 免费档每次签发固定扣额 ≈ 1 次 Flash 纪要。 */
export const FREE_PER_ISSUE_SECONDS = 120;
