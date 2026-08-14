# recap-cloud

Recap「凭证签发器」后端。后端**不碰用户音频/文本**,只做三件事:验证 Pro 权益 → 签发阿里短期临时 token(≤30min)→ 计量配额。客户端拿临时 token **直连**阿里 wss(与 BYOK 路径同构)。

部署:Cloudflare Workers + 备案自定义域名。

## 落地路线(7 步)

| # | 步骤 | 依赖 |
|---|------|------|
| **1** | **P0:验证 st-token 能否 Bearer 连 ASR wss** | ← 当前 |
| 2 | P0:验证备案域名国内三网稳定性 | — |
| 3 | Workers 工程骨架(wrangler + TS) | 1 |
| 4 | `/v1/issue` 核心实现(JWS 验签 + 阿里签发 + per-user 配额) | 1, 3 |
| 5 | 部署 Cloudflare + 绑定备案域名 | 4 |
| 6 | 客户端 RecapCredentialProvider + ASR/LLM 接入 | 4 |
| 7 | 端到端联调 + LIVE 续签/配额/稳定性实测 | 5, 6 |

## Step 1:P0 验证(gating,必须先跑通)

验证方案的技术地基:阿里「临时 API Key」能否像主 key 一样 `Bearer` 直连 `fun-asr-realtime` WebSocket。

```bash
cd cloud
npm install                              # 装 ws(验证脚本用)
export DASHSCOPE_API_KEY=sk-xxxxxxxx     # 真实阿里百炼主 key(须开通 fun-asr-realtime)
node scripts/verify-sts-asr.mjs
```

**判定**
- `✅ PASS`(主 key 与 st-token 都 `task-started` 成功)→ 地基成立,推进 Step 3。
- `❌ FAIL`(主 key 通、st-token 不通)→ wss 对临时 token 可能要求不同 header。**把 B 的失败信息贴回**,方案结构不变,只改客户端 header 一处。
- `⚠ INCONCLUSIVE`(主 key 基线就不通)→ 先确认 key 有效/已开通模型/网络,再重跑。

**安全**:主 key 只从环境变量读,本脚本绝不写凭证到文件。上线后这把主 key 只放 Cloudflare Secrets,**永不下发客户端**;客户端只拿到 60s–30min 的临时 token。

## 上线前部署验证清单(按序执行)

```bash
# 0) 单元测试 + 类型检查
npm test && npx tsc --noEmit

# 1) 主 key 白名单核对(百炼控制台给子账号配「模型访问限制」):
#    ASR: fun-asr-realtime + paraformer-realtime-v2 ; LLM: qwen-plus
#    漏开 → st-token 403;多开 → 免费用户可持 ASR 桶 token 刷高价模型。
DASHSCOPE_API_KEY=sk-xxxx node scripts/verify-sts-asr.mjs   # st-token 连 ASR wss
DASHSCOPE_API_KEY=sk-xxxx node scripts/verify-sts-llm.mjs   # st-token 调 qwen-plus 白名单

# 2) 网关端到端(先 wrangler deploy,再打生产域名):
node scripts/verify-gateway-asr.mjs   # 含负向探针:ASR token 调 qwen-plus 必须 403(越权隔离)
node scripts/verify-gateway-e2e.mjs   # 免费档 /v1/issue → 消费 → 配额耗尽 403 全链路

# 3) Pro 真实验证(TestFlight 沙盒):
#    a. wrangler secret put APPLE_PRIVATE_KEY/APPLE_KEY_ID/APPLE_ISSUER_ID/APPLE_BUNDLE_ID
#    b. 沙盒期:APPLE_STOREKIT_HOST=https://api.storekit-sandbox.it.com(TestFlight 交易只在沙盒 API 可查;
#       生产 host 查沙盒交易 → 404 → isPro=false)
#    c. 真机 TestFlight 装包 → 购买订阅 → 走纪要管线 → 确认网关日志 verify 命中 + 配额 DO 扣减
#    d. 正式提审前切回生产 host(wrangler secret put / env 移除覆盖)并再验一次真机购买

# 4) 可观测性:Cloudflare 控制台 → Workers → recap-cloud → Logs(observability 已开启,保留 3 天)
#    prove/issue/quota 路径的 console.log 在此可查;上线后每周扫一次 403/502 分布。
```

## 技术要点(供后续步骤参考)

- **签发**:`POST https://dashscope.aliyuncs.com/api/v1/tokens?expire_in_seconds=1800`,主 key Bearer 鉴权,返回临时 token(`st-` 前缀,有效期 1–1800s)。
- **直连**:客户端用临时 token 作 `Authorization: Bearer` 连 `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`(即现有 `FunASREngine` 的 key 来源换成临时 token,协议零改动)。
- **权限继承**:临时 token 继承主 key 全部权限 → **主 key 必须是 RAM 最小权限子账号,只开 `fun-asr-realtime`(+指定 qwen 模型)**。
- **配额**:per-user 月度累计签发时长,超限拒签(只在签发阀门做,不在音频流上做)。
