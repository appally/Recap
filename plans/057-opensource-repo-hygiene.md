# Plan 057: 开源 repo 卫生包——License / README / CI / 历史清洗

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（《开放化战略》Phase 0；**硬依赖 056**——Key 未出二进制前严禁公开）
- **Effort**: S（文档 + CI + 一次性历史处理；无业务代码）
- **Risk**: LOW（唯一风险是历史清洗误删，先做镜像备份）
- **Depends on**: **056 硬**（且 056 的 Key 轮换已完成）
- **Category**: infra / oss

## Why this matters

开源的信用来自第一眼 repo：LICENSE 决定大厂能不能白嫖闭源 fork，README 决定开发者 5 分钟内能否跑起来，CI 绿徽章 + 密钥扫描是「这个项目是认真的」的最强信号。既有 91 个测试文件是现成资产，只差一条 workflow 把它变成公开的、持续的可信度。

## Implementation

### Wave A: License 与三方声明

1. `LICENSE`：**AGPL-3.0**（战略定稿：对闭源 fork 构成门槛，与反锁定品牌一致；版权人保留 App Store 双重许可权利）。README 加「License 与商业使用」一节说明双重许可。
2. `NOTICE`/README 附表列三方依赖与 license：MacPaw/OpenAI 0.5.1（MIT）、ArgmaxOSS SpeakerKit 1.0.0、FluidAudio 0.15.6、随包 CoreML 声纹模型的分发条款——逐项核对各自 LICENSE 后填表，**任何一项不允许再分发即停下报告**。
3. 云端 `cloud/` 与 App 同 repo 同 license。**公开反滥用参数收敛（诊断 F6）**：`env.ts` 中的限流/配额可调常量（`ISSUE_IP_MAX_PER_HOUR`、`ISSUE_IP_MAX_DEVICES_PER_HOUR`、各桶秒数、宽限天数）迁为 wrangler vars（代码留现值作默认），公开 repo 后阈值不再是一次 grep 可得的攻击说明书，且可随时收紧不发版。

### Wave B: README 与贡献者基建

1. `README.md`（根目录，中文为主 + 顶部英文摘要段）：是什么（开放的本地会议记忆）、三大能力一句话、架构图（Modules 五框架 + cloud 网关）、**自建路径**（clone → xcodegen → 打开模拟器，「不花钱不注册」路径要点明）、**「你的数据在哪」安全模型一节**（本机 SwiftData/音频、BYOK 提供商边界、托管层可关）。
2. `CONTRIBUTING.md`：代码贡献流程（plan 文化一句话带过）、模板/技能作为数据贡献的低代码入口（指向 060 的文件格式）、scope 纪律（不做主动弹窗/不做通用笔记等既有决策摘要）。
3. `.github/ISSUE_TEMPLATE/`（bug / feature 两张表）+ `CODE_OF_CONDUCT.md`。
4. `docs/security-model.md`（诊断 F10/F12）：威胁模型一页——自定义端点收到什么数据、恶意 SKILL.md/配方能做什么不能做什么、声纹不导出、Key 永不入工作区/导出物。`docs/schema.md` 骨架（062 开放格式契约占位：`meetings/<id>/` 目录结构与字段）。
5. README 附 FAQ（诊断 F15，第一波 issue 可预测）：「如何获取各家 Key（附链接）」「我的模型不支持 XX 怎么办」「本地模式与云端模式的区别」「数据存在哪」。

### Wave C: CI

`.github/workflows/ci.yml`（macOS-15 runner）：

1. `brew install xcodegen` → `cd RecapApp && xcodegen generate && sh scripts/fix_scheme.sh`。
2. Build：`xcodebuild -project RecapApp.xcodeproj -scheme RecapApp -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO`。
3. Test：按 plans/README「How to execute」的 test 命令跑 RecapModelsTests/RecapLLMTests（如单 runner 时长超限，拆 build/test 两个 job 并裁剪 -only-testing 集合，**不得静默跳过**，README 记录覆盖范围）。
4. Gitleaks action 扫全 repo（含 push 的历史）。

### Wave D: 历史与资产清洗（公开前一次性）

1. 备份镜像：`git clone --mirror` 到仓外。
2. 历史处理二选一（推荐 ①）：
   - ① 就地 `git filter-repo --replace-text`（替换已泄露旧 Key 等敏感串；056 已轮换，这里只是移除字符串防误用）+ force push；
   - ② squash 重初始化（单 commit 首版）——丢失 plans 执行史，不推荐但最省事。
3. 个人资产不入公开 repo：根目录 `ChatGPT Image *.png`、`avater*.png`、`ICON*.png`、`SpeechDemoIOS.zip`、`*.md` 中的内部调研稿是否公开由用户拍板——**默认方案：`production-docs/` 与根目录调研 md 保留公开**（它们是社区信任资产），图片/zip 移出或加 `.gitignore` + `git rm --cached`。
4. 发布工程（诊断 F10）：`RELEASES.md` 定流程（tag 命名 / CHANGELOG / App Store 与 GitHub release 版本对应 / 公告模板）；公开 `ROADMAP.md`（Batch R + Phase 2+ 摘要，社区预期从第一天管理）。
5. 公开前检查单：`production-docs/` 与根目录调研 md **逐份过**（个人路径/内部措辞/联系方式），默认公开但允许单独移出；「Recap」名称商标冲突粗查；隐私政策页补「源代码公开」声明；维护 `docs/verified-combos.md` 首版（验证组合清单，F10 兼容矩阵承诺物）。
6. 公开发布：GitHub repo 设 description/homepage，首个 tag `v0.9.0-oss`。

## Verification

1. 新 clone 到陌生目录，仅按 README「自建」步骤在模拟器跑起 App（录音权限后能进首页）。
2. CI 在 main 分支全绿（build + test + gitleaks 0 finding）。
3. `git log --all -S <旧中转Key前缀> --oneline` 零命中（历史清洗生效）。
4. LICENSE/NOTICE 存在且依赖表逐项有 license 结论。

## STOP conditions

- 任一三方依赖/模型的 license 不允许随开源 repo 再分发——停下报告依赖名与条款，勿自行替换依赖。
- CI 上 macOS runner 跑不了 iOS 26 destination（runner Xcode 版本不够）——降级为「build-only + 单测本地跑」并在 README 如实标注，不装绿。

## 执行记录（2026-09-28）

- **Wave A DONE**：`LICENSE`（AGPL-3.0 gnu.org 官方全文 661 行）；`NOTICE.md`（SPM 六依赖逐一核实：MacPaw OpenAI / argmax-oss-swift = MIT；FluidAudio / swift-openapi-runtime / swift-http-types / swift-argument-parser = Apache-2.0；与 AGPL 分发兼容）。**唯一未结项**：随包 CoreML 模型文件（`App/speakerkit-coreml/` 等）的 HF 模型卡原文逐一再分发确认——不过则改运行时下载（NOTICE 已标注 ⚠️）。
- **Wave B DONE**：`README.md`（英文摘要 + 中文主体：能力 / 自建路径（含 arm64 destination 坑）/ 架构 / FAQ / 合规提醒）；`CONTRIBUTING.md`（三种贡献重量级：技能配方数据文件 → issue+数据 → 代码；xcodegen/fix_scheme 工程约定）；`CODE_OF_CONDUCT.md`；`.github/ISSUE_TEMPLATE/{bug,feature}.md`（bug 模板含供应商/引擎环境字段）。`docs/security-model.md`、`docs/schema.md` 早前已写。
- **Wave C DONE**：既有 `ci.yml`（8 月建的 cloud+ios 两 job）修复 ios build 的 `generic` destination x86_64 链接坑（改动态解析具体模拟器 UDID）；**新增 `secrets` job**（gitleaks 全历史扫描）。
- **Wave D 待拍板（见下方清单）**：好消息——旧中转 Key 从未入 git 历史（`git log -S` 零命中），filter-repo 大概率不需要；已核实图标等资产**在** git 跟踪中（`git ls-files` 命中 ICON*.png 等），公开前需 `git rm --cached`。
- **状态：IN PROGRESS**（Wave A–C 全部落地；Wave D 等用户拍板资产清单后执行公开推送）。
