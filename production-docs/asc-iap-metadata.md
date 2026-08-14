# App Store Connect 内购提交材料（Guideline 2.1(b) 修复）

> 背景：1.0(1) 审核被拒原因之一是「应用内包含订阅引用，但关联的内购产品未提交审核」。
> 产品 ID 权威来源：`RecapApp/Modules/RecapModels/MembershipProducts.swift` + `RecapApp/App/Recap.storekit`。
>
> **✅ 2026-08-14 已通过 asc CLI 写入 ASC**（App 6796373905）：
> - 三个产品 zh-Hans 本地化已全部补齐/修正（此前年度为空、月度/BYOK 是「名称当描述」的占位垃圾文案）
> - ⚠️ 实测硬限制：**订阅/IAP 本地化描述 ≤55 字符**，下述草稿为实际写入版
> - 实际定价：月度基准 $3.99（¥25）、年度 $29.99（¥198）
> - **剩余阻塞：三个产品全部缺 Review 截图**（审核信明说无截图不能提交）

---

## 一、产品本地化元数据（已写入 ASC 的最终版）

### 1. 纪要 Pro 月度（自动续订订阅）

* **产品 ID**：`com.liuyong.recap.pro.monthly` · 订阅 ID `6796589012` · 版本 `575ac165`
* **显示名称**：纪要 Pro 月度
* **描述**（29 字符）：解锁云端高精转写与全部纪要能力，按月自动续订，可随时取消。
* **状态**：READY_TO_SUBMIT（缺截图）

### 2. 纪要 Pro 年度（自动续订订阅）

* **产品 ID**：`com.liuyong.recap.pro.yearly` · 订阅 ID `6796592135` · 版本 `36d06e64`
* **显示名称**：纪要 Pro 年度
* **描述**（29 字符）：解锁云端高精转写与全部纪要能力，按年自动续订，可随时取消。
* **状态**：MISSING_METADATA → 本地化+定价已补齐，等 ASC 重算（或上传截图后转正）

### 3. 自备密钥解锁（非消耗型，原 BYOK 解锁）

* **产品 ID**：`com.liuyong.recap.byok.unlock` · 版本 `c647cf5b`
* **显示名称**：自备密钥解锁
* **描述**（30 字符）：一次性买断，绑定你自己的大模型 API Key，无订阅约束。
* **状态**：READY_TO_SUBMIT（缺截图）

---

## 二、App Review 截图

每个产品需要一张审核截图（IAP 提交必填项）：

1. 模拟器/真机运行 App → 设置 → 会员（未购买状态）。
2. 截取「Pro 订阅」Tab：需同时可见 **两个订阅价格与周期**（¥25/月、¥198/年 + 约 ¥16.5/月）以及底部的 **用户协议 / 隐私政策** 链接。
3. BYOK 产品可截「自备密钥」Tab（¥68 买断价格可见）。
4. iPhone 6.9" 与 iPad 13" 各一张更稳妥（iPad 审核设备为 iPad Air 11-inch M3）。

---

## 三、提交流程 Checklist

1. ~~zh-CN 本地化~~ ✅ 2026-08-14 已由 asc CLI 写入（见上）。
2. ~~自定义 EULA~~ ✅ 已创建（覆盖全部 51 个销售地区，全文 701 字符）；~~隐私政策 URL~~ ✅ app-info 层本就已设（此前看到的 null 是 version 层废弃字段）；~~副标题~~ ✅ 已改为去品类化版本。
3. [ ] **上传三个产品的 Review 截图**（唯一剩余的 IAP 阻塞）：
   - 手动：ASC 网页每个产品上传
   - CLI：`asc subscriptions review screenshots create --subscription-id 6796589012 --file ./pro-monthly.png`（年度同理）；BYOK 用 `asc iap ...` 对应命令
4. 上传新二进制 build 1.0(2)（版本号已在 `project.yml` bump 为 2）。
5. 版本页向下找到 **App 内购买项目** 区域 → **勾选全部三个产品**（⚠️ 不勾选 = 2.1(b) 原样复现）。
6. 提交审核。
7. 回复审核信（见 `appstore-review-reply.md`），3.1.2(c) 部分附付费流程屏幕录制。

---

## 四、英文本地化（可选但建议）

若 App 在非中区商店销售，每个产品需英文本地化：

* Pro Monthly — **Jiyao Pro Monthly** — "Unlock cloud transcription and smart minutes: dialect re-transcription, long-meeting transcription, templates and AI assistant. Auto-renews monthly."
* Pro Yearly — **Jiyao Pro Yearly** — "Unlock cloud transcription and smart minutes: dialect re-transcription, long-meeting transcription, templates and AI assistant. Auto-renews yearly."
* BYOK Unlock — **Bring Your Own Key** — "One-time purchase. Use your own LLM API key (DeepSeek, Qwen, Kimi, GLM, OpenAI, Gemini…) to power minutes and transcription. No subscription."
