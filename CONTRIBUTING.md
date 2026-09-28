# 贡献指南

谢谢你想让 Recap 更好。这个仓库有一些自己的工作方式，先花三分钟读完，能省你很多来回。

## 先核对范围

动手前请过一遍 [ROADMAP.md](ROADMAP.md) 的「不做」清单——团队协作、通用笔记、通话录音、硬件、主动弹窗式 coaching、云端全量记忆、核心功能计量，这些是有意不做的（定位依据见根目录两份战略文档）。拿不准先开 issue 讨论。

## 三种贡献方式（按重量排序）

1. **技能 / 模板 / 供应商配方（无需写代码）**：它们是数据文件（SKILL.md / 配方 JSON，格式见 `docs/schema.md` 与 `RecapApp/Modules/RecapLLM/Agent/Skills/AgentSkillDocument.swift`）。提 PR 加文件即可，Review 成本最低。
2. **问题与数据**：带环境信息的 bug 报告（模板在 `.github/ISSUE_TEMPLATE/`）、真实会议上的失败样本（先抹敏感内容）都很有价值。
3. **代码**：先开 issue 对齐方案再动手；改动附单测（`RecapApp/Tests/` 三套件 + `cloud/test/`）。

## 工程约定

- **加/删 Swift 文件后必须重跑** `xcodegen generate`（工程由 project.yml 生成）+ 仓库根 `sh scripts/fix_scheme.sh`，否则别处构建会挂。
- 构建/测试用**具体模拟器 destination**（arm64-only，原因见 README 自建一节）。
- Swift 6 并发纪律：内核（AgentKernel/AgentTransport）不 import SwiftUI、不写 SwiftData；跨隔离的 bool 用锁盒模式（参考 `AsrEngine.swift` 的 `EngineFlag`）。
- 迁移类改动（UserDefaults 键、持久化 schema）先在 PR 里写清楚回滚路径。
- 网关改动跑 `cd cloud && npx vitest run && npm run typecheck`；涉及部署由维护者执行。

## 提交 PR

- 分支从 `main` 拉；commit 信息中文/英文均可，说清「为什么」。
- 提交 PR 即表示你同意以 AGPL-3.0 授权你的贡献（无 CLA）。
- 仓库用编号 plan（`plans/`）管理批次执行——大型改动会先以 plan 形式对齐验收门槛再实施，这是刻意的节奏，不是官僚。

## 行为准则

见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。对事不对人；用中文或英文都行。
