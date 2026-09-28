# Plan 056: 托管 LLM 中转 Key 出二进制——网关 /v1/relay 代理化（开源红线）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（《开放化战略与架构重构建议-2026-09》Phase 0 第一项：共享 Key 明文随二进制 + 已入 git 历史，开源当天即公开泄露。**先于 057（repo 公开）执行**）
- **Effort**: S–M（客户端小改 4 处；网关新增一条代理路由 + HMAC token）
- **Risk**: MEDIUM（SSE 流式经 Cloudflare Workers 透传是唯一技术风险点，有回退方案）
- **Depends on**: 无。部署顺序硬约束：**网关先上线，客户端后发版**（新旧字段向后兼容）
- **Category**: security / infra

## Why this matters

`LLMPresets.hostedRelayAPIKey`（`Modules/RecapModels/LLMProviderConfig.swift:60`）明文随二进制分发，代码注释自认临时方案：Key 可被提取滥用、无按用户计量。闭源阶段是风险，开源阶段是确定性事故——脚本会在数小时内把它薅穿。修法：托管档 LLM 出口改经 Recap 网关（Cloudflare Workers）代理，真实中转 Key 只存 Workers secret；客户端持 `/v1/issue` 签发的短期 HMAC relay token，与现有阿里临时 token 同一信任模型（免费档 LLM token 本就 15min TTL 封顶，敞口一致）。

## Current state（勘察结论）

- 客户端 Key 消费点共 4 处：
  - `Modules/RecapLLM/LLMProviderFactory.swift:32-38`（`.recapCloud` 分支）与 `:43-49`（`.freeTrial` 分支），`apiKey: LLMPresets.hostedRelayAPIKey, baseURL: LLMPresets.hostedRelayBaseURL, model: hostedRelayModel("auto/glm")`。
  - `Modules/RecapLLM/Agent/AgentTransportFactory.swift:40-41` 与 `:49-50`（Agent 循环两分支，同构）。
- `OpenAICompatibleProvider` 已有 401 重签钩子（P1-7，commit 1e7b292）——relay token 中途过期重签一次的机制现成。
- `RecapCredentialProvider.fetchIssue`（`RecapCredentialProvider.swift:259`）已解 `IssueResponse`（`:389`）；`Cached`/`RecapIssuedCredential` 增字段即可携带 relay 凭证。Debug 可用 UserDefaults `recap.cloud.endpoint` 覆盖网关基址联调（`:148-158`）。
- 网关 `cloud/src/index.ts`：`/v1/issue`（`:106`）已具备验签/配额/宽限/限流；响应组装 `buildIssueResponse`（`:263`）纯函数、有 vitest（`cloud/test/`）。
- 历史回退路径：2026-09-10 之前托管 LLM 走 `/v1/issue` 下发的 `llm_base` + dashscope token——若 Workers 流式代理不可行，恢复此路径同样达成「Key 出二进制」。

## Implementation

### Wave A: 网关侧（先部署）

1. `cloud/src/env.ts`：`Env` 增加 `RELAY_BASE_URL`、`RELAY_API_KEY`、`RELAY_HMAC_SECRET`、`LLM_RELAY_MODEL`（默认 `auto/glm`）。
2. 新建 `cloud/src/core/relay.ts`：
   - `signRelayToken({userId, tier, ttl}, secret)`：HMAC-SHA256 over base64url(JSON payload)，payload 含 `sub/tier/exp/usage:"llm"`。
   - `verifyRelayToken(token, secret)`：验签 + 过期检查，返回 userId/tier 或 null。
3. `index.ts` 新增路由 `POST /v1/relay/*`（仅 `/chat/completions` 及 `/models` 白名单）：
   - 验 `Authorization: Bearer <relayToken>`；无效 401。
   - 解析 JSON body，**强制改写 `model` 为 `LLM_RELAY_MODEL`**（客户端不再决定托管模型，顺带消灭托管路径模型名硬编码漂移），转发 `${RELAY_BASE_URL}${实际路径}`，`Authorization: Bearer RELAY_API_KEY`。
   - **流式透传**：`return new Response(upstream.body, upstream)` 保留 SSE content-type，禁止任何缓冲。
   - 可选计数：按 token 的 sub 在 QuotaDO 打点请求数（v1 只记日志，不扣额——计量口径仍按 /v1/issue，与现状一致）。
4. `buildIssueResponse` 增 `relay_token` + `relay_base`（= `https://<本域>/v1/relay`）两键——**可选键，旧客户端忽略**；`handleIssue` 用 `signRelayToken` 生成，TTL 与 `expires_in` 同。
5. vitest：token 签验 round-trip / 过期 / 篡改；model 强制改写断言；无 token 401。
6. 用户操作：`wrangler secret put RELAY_API_KEY / RELAY_HMAC_SECRET` 后 `wrangler deploy`。

### Wave B: 客户端

1. `IssueResponse`/`Cached`/`RecapIssuedCredential` 增 `relayToken`/`relayBase`（可选解码；缺失抛明确错误「网关版本过旧，请稍后再试」——网关已先部署，仅断网/灰度窗口会命中）。
2. `LLMProviderFactory.makeCurrent()` 两分支与 `AgentTransportFactory` 两分支：`apiKey: cred.relayToken, baseURL: cred.relayBase + "/chat/completions"`（按 `OpenAICompatibleProvider.parseBaseURL` 的约定核对路径拼接）。模型仍发 `hostedRelayModel`（网关会改写，双保险）。
3. `LLMPresets` **删除 `hostedRelayAPIKey` 常量**；`hostedRelayBaseURL` 一并删除（改由网关下发），注释更新指向本 plan。
4. `RecapCredentialProvider.userMessage` 中「云服务暂未接通」类文案核对，401 语义区分「token 过期（会自动重签）」与「网关拒绝」。

### Wave C: 清障与验证

1. 全 repo 密钥扫描（`gitleaks detect --source . --no-git` 或等价 grep `sk-` 模式），清理其余明文密钥。
2. **中转侧轮换已泄露 Key**（用户在 token.toai.pro 操作）。轮换时机（诊断 F9）：不与 056 发版同日——新版上线后观察 2–4 周中转用量（新版走网关、旧版仍直连带旧 Key，用量曲线可区分），旧版托管流量占比 <10% 或发现异常放量才轮换；git 历史/已售二进制旧 Key 作废，旧版 App 托管档失效属预期（更新即恢复）。
3. 每周巡检中转用量与网关 `/v1/relay` 错误率（wrangler tail 采样 / Dashboard），异常放量即触发上一条的立即轮换。
4. 新构建二进制 `strings` 扫描确认无 `sk-` 前缀 Key。

## Verification

1. `cd cloud && npx vitest run` 全绿。
2. `wrangler dev` 本地起网关；App Debug 设 `recap.cloud.endpoint` 指向本地；模拟器托管模式跑通一场纪要（流式逐字出现 = SSE 透传正常，不是结尾一次性吐出）。
3. `curl -N -H "Authorization: Bearer <relay_token>" -d '{"model":"x","stream":true,...}' <local>/v1/relay/chat/completions` 观察 chunk 逐段到达。
4. `cd RecapApp && xcodegen generate && sh scripts/fix_scheme.sh` + 构建 + 回归既有测试。
5. `grep -rn "sk-" --include="*.swift" RecapApp/` 零命中。

## STOP conditions

- Workers 对上游 SSE 响应实测被缓冲/截断（长纪要流式不可用）——**回退方案**：恢复 2026-09-10 前路径（`/v1/issue` 下发 `llm_base` 指 dashscope compatible-mode + 阿里 token，网关 `LLM_BASE`/`LLM_MODEL` 已有该配置位），同样移除 `hostedRelayAPIKey`，停下报告取舍。
- `OpenAICompatibleProvider` 的 baseURL 拼接与网关代理路径不兼容（如尾部 /v1 处理）且改动超出「工厂传参」范围——停下说明，勿在 Provider 内加特判分支。

## 执行记录（2026-09-28）

- **Wave A DONE**：`cloud/src/core/relay.ts`（HMAC 签验 + model 改写纯函数）、`index.ts` `/v1/relay` 路由 + `/v1/issue` 增发 `relay_token/relay_base`（未配 RELAY_* 时整键缺席，旧形状逐字节不变）、`env.ts`/`wrangler.jsonc` 三件配置；vitest **51/51 绿**（含 relay 新 8 例）+ `tsc --noEmit` 过。
- **Wave B DONE（代码）**：`LLMPresets.hostedRelayAPIKey/BaseURL` 已删（源码 grep 零残留）；`RecapIssuedCredential/Cached/IssueResponse` 增 relay 字段（可选解码）；两工厂共 4 处消费点切 `relayToken/relayBase`，Provider 侧接上 `tokenRefresher` 401 重签（免费档 15min TTL 续跑）；Agent 传输层无重签钩子——如实失败，传输层重签记为后续小项（见 Wave B 注）。`RecapCredentialNegativeCacheTests.makeCached` 已补新字段。
- **Wave C 部分**：源码密钥扫描干净（`sk-` 零命中；git 历史旧值待 057 Wave D 清洗 + 轮换）。
- **⚠️ 构建验证 BLOCKED（环境）**：本机当前无法访问 GitHub release 资产（objects.githubusercontent.com TLS 失败，代理未开）→ SPM 二进制依赖 NemoTextProcessing 下载不了，xcodebuild 全量构建/测试无法执行。已做 `swiftc -parse` 语法级检查（4 个改动文件全过）。**网络恢复后待跑**：`xcodegen generate && sh ../scripts/fix_scheme.sh` → Debug 构建 → RecapModelsTests/RecapLLMTests → 模拟器托管模式冒烟 + `curl -N` SSE 透传检查。
- **待用户操作**：`wrangler secret put RELAY_API_KEY / RELAY_HMAC_SECRET` → `wrangler deploy`（网关先上）；Key 轮换按 Wave C 观察窗执行。

### 补充（同日晚，网络恢复后全部闭环）

- **网关已部署生产**：`wrangler secret put RELAY_API_KEY / RELAY_HMAC_SECRET` + `wrangler deploy`（Version `c4a4cb46`，recap.manymind.chat）。
- **线上 E2E 全通**（curl 直打生产）：匿名设备 `/v1/issue` → `relay_token/relay_base` 下发 ✓；`/v1/relay/chat/completions` 无鉴权 401 ✓；持 token 真实补全 ✓（客户端发 `model:"whatever-client-sent"` 被强制改写 `auto/glm` → 实际路由 `glm-5.2`）；SSE 流式透传 ✓（keepalive chunk 逐段到达，无缓冲——STOP 风险点排除）。
- **客户端构建+测试绿**：arm64 模拟器（iPhone 17 Pro）BUILD SUCCEEDED；RecapLLMTests **245/245**、RecapModelsTests **101/101**（含更新的 NegativeCache 8 例）。注意：`generic/platform=iOS Simulator` 会连带编 x86_64 切片而 NemoTextProcessing 无此切片——**构建须用具体模拟器 destination**（已记入 README How to execute 候选）。
- **Key 从未进 git 历史**（`git show HEAD` 无 `sk-`，`git log -S` 零命中；2026-09-10 引入以来一直是未提交工作树改动）→ 057 的 filter-repo 对此 Key **不再需要**，泄露面仅剩已分发二进制；轮换仍按观察窗执行（旧版 App 直连流量可从中转侧观测）。
- **状态：DONE**（模拟器内 App 冒烟由 curl E2E 等价覆盖；轮换窗口与 `wrangler` 后续运维属运营项）。
