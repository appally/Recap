# 重新提审前待办清单（2026-08-15 审计后）

> 本清单为「代码/网关侧已完成」之外必须人工执行的 ASC 后台操作。
> 前置：本次审计修复已全部完成代码侧（见文末「已完成」）。

## 1. 网关部署（代码已改，待 deploy）

```bash
cd cloud && npx wrangler deploy
```

- [ ] 部署后验证：
  - `https://recap.manymind.chat/privacy` 含「声纹说话人识别」章节、生效日期 2026-08-15
  - `curl -X POST https://recap.manymind.chat/v1/account/delete` 返回 401（无 token 时）

## 2. ASC 后台操作（上次拒审的收尾，缺一即复拒）

- [ ] 三个 IAP（pro.monthly / pro.yearly / byok.unlock）上传 **Review 截图**（当前唯一 IAP 硬阻塞）
- [ ] 版本页「App 内购买项目」**勾选全部三个产品**（不勾 = 2.1b 原样复现）
- [ ] 版本页**同步新描述/副标题/关键字**（以 `app store.md` 为准；回信已宣称 revised，ASC 必须一致）
- [ ] 复核 EULA 字段已填 `https://recap.manymind.chat/terms`（3.1.2c，材料显示已建，再确认一遍）

## 3. 隐私问卷与年龄分级

- [ ] ASC 隐私问卷与 `RecapApp/App/PrivacyInfo.xcprivacy` 逐项对照：
  Audio Data / User Content / Device ID / Location / Purchase History，
  均 = 收集·AppFunctionality·不追踪·不关联身份（Location 注意：坐标经 CLGeocoder 反编码会出端，声明成立）
- [ ] 年龄分级问卷逐题落档（建议新增记录文件）：
  预期 4+；「无限制网络访问」答 **否**（AI 深度调研为服务端检索，App 内不提供任意网页浏览）

## 4. 审核备注（App Review Information）

- [ ] audio 后台模式用途：「长时间会议录音与实时转写需要持续音频会话」
- [ ] Apple Intelligence 机型说明：「端侧免费转写需 Apple Intelligence 机型（iPhone 16 系列等）；
      非 AI 机型可登录后使用云端档（免费额度）或升级 Pro」——与商店描述保持一致
- [ ] AI 生成内容说明（中国区）：云端模型为阿里百炼 qwen-plus（阿里已备案模型），App 为 API 调用方
- [ ] 中国区保留决策（2026-08-15 用户拍板）：**保留中国大陆上架**。后续建议尽快推进
      ICP/App 备案与 `recap.manymind.chat` 域名备案，备案完成后在官网页脚补备案号展示

## 5. 提审前验证

- [ ] 沙盒账号：购买（月度）→ 取消续订 → 恢复购买 → BYOK 买断 → 恢复购买（文案区分 BYOK/Pro）
- [ ] 删除账户全流程真机走一遍：Apple 账号 → 二次验证 → 服务端 200 → 本机清除
- [ ] Archive 上传，确认 ITMS 全绿（重点：无 90474 CFBundleVersion Mismatch——本次已修 Controls 扩展版本号）
- [ ] Release 包 `strings` 抽查无 "Plaud" / "周会·产品评审"（DemoContent 已 #if DEBUG 门控）
- [ ] 回信签名档补开发者姓名后发送 Resolution Center 回复 + 随信录屏（20–40s：登录→录一场→看纪要→隐私政策/用户协议/恢复购买路径）

---

## 已完成（2026-08-15，代码/文档侧）

1. **Controls 扩展版本号**：project.yml `info.properties` 显式写 `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`，appex 与主 App 同为 1.0(2)（修 ITMS-90474）
2. **Plaud 痕迹清零**：`PlaudAskBar→AgentAskBar`、`PlaudInputBox→MinimalInputBox` 等 7 组符号改名 + 全部注释清理，源码 grep 零命中
3. **隐私政策**：补声纹生物识别专节（端内处理/单独同意/删除路径）、点名阿里 DashScope 与数据位置、生效日期 2026-08-15；App 内嵌 privacySummary 同步
4. **账号删除（5.1.1(v)）**：网关新增 `POST /v1/account/delete`（identityToken 验签 + DO `/wipe`）；客户端 Apple 账号删除走二次 SIWA 验证；确认文案修正；本机账号保持本地清除（服务端无账户数据）
5. **付费文案**：「免费试用」→「免费版」；恢复购买文案按 Pro/BYOK 区分；BYOK tab 显示买断条款而非订阅自动续订条款
6. **开源致谢页**：设置→关于→开源许可致谢（7 组件 license 按本地 checkout 核实 + 3 类模型权重来源与条款）
7. **杂项**：麦克风文案补后台录制说明；DemoContent/startMockStream/startExplicitDemoLive 包 `#if DEBUG`；RecapCredentialProvider 过时「占位」注释清理
8. **官网绝对化宣称**：「绝不丢失」→「断点落盘保护」；「无限量」→「大容量（合理使用配额）」
9. **回信占位符**：开发时长（since July 2026）与 270+ Swift 文件已填；签名姓名待补
