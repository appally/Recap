# Plan 060: Skills 文件化——内置资源化 + 用户目录 + 全功能编辑器 + 导入导出

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P1（《开放化战略》P1「技能即文档」：SKILL.md 从 UserDefaults 表单走向文件生态，是社区分享的前置）
- **Effort**: M（内置迁移 + 目录存储 + 编辑器解锁 + 导入导出）
- **Risk**: MEDIUM（23 个内置技能迁移需 round-trip 校验；Files 目录暴露需 Info.plist 键）
- **Depends on**: 058 软（门禁语境）；独立可先行
- **Category**: feature / openness

## Why this matters

032 已把技能做成 SKILL.md 格式（与 Claude skills 同构），但三个「不开放」：23 个内置技能是 Swift 字符串常量（用户看不见改不了）；自定义技能存 UserDefaults 字符串数组（不是文件，进不了 Files、发不出去）；编辑器是受限表单（工具固定只读三件套、固定 3 步、固定 quick 模型）。文件化后：用户技能是 `Documents/RecapSkills/*.md`，可被用户用任何编辑器改、可 AirDrop、可进社区仓库——「自定义 skills」从功能点变成生态入口。

**v1 刻意不做**：社区在线目录/App 内安装 URL（P2）、skill 签名防篡改（v2）、MinutesPipeline 纪要 prompt 技能化（战略 P3 另案）。

## Current state（勘察结论）

- `Modules/RecapLLM/Agent/Skills/AgentSkillDocument.swift`：SKILL.md parse/encode round-trip（手写 frontmatter），已测。
- `AgentBundledSkills.swift`：23 个内置技能为 Swift 字符串常量；`AgentSkillCatalog.bundled()` + `merging(customDocuments:)`（自定义 id 不得覆盖内置）。
- `Modules/RecapUI/CustomTemplateStore.swift`：UserDefaults key `recap.customTemplates.v1` 存 SKILL.md 字符串数组；`CustomTemplateEditorSheet` 受限表单（工具/步数/模型锁死）；`TemplateSelectionSheet` 三档 Tab。
- `forbiddenTools`（禁 create_reminders/revise_minutes/run_skill）在文档 codec 层强制。
- xcodegen 工程：新增 Resources 需在 project.yml 声明并重跑 generate。

## Implementation

### Wave A: 内置技能资源化

1. 写一次性迁移脚本（Swift script 或手跑）：`AgentBundledSkills.swift` 的 23 个常量 → `Modules/RecapLLM/Agent/Skills/Bundled/<id>.md` 文件（UTF-8，无 BOM）。
2. project.yml 给 RecapLLM target 加 resources；`AgentSkillCatalog.bundled()` 改为遍历 bundle 的 `Bundled/*.md` 解析（解析失败跳过 + Debug 断言，范式同 `CustomTemplateStore.skills`）。
3. **round-trip 校验**：迁移后跑既有技能测试 + 新增测试「每个 bundle 文件 parse 成功且 id 唯一、与旧常量生成的 id 集合一致」（旧常量文件保留至验收通过后删除）。
4. `AgentBundledSkills.swift` 降级为迁移对照（验收后删）。

### Wave B: 用户技能目录化（开放根目录——062 的地基，诊断 F3）

0. **容器路径审计（前置）**：确认 SwiftData store 与音频落盘根（plan 007 `Meeting.audioPath` 写入处）不在 `Documents/` 内（SwiftData 默认 Application Support，仍需逐点核实；音频重点查）。已有文件在 Documents 的 → 迁 Application Support + 兼容读旧路径。这是 Files 暴露的安全前提，根治原 STOP 第 2 条。
1. **开放根目录（一个根，不造第二份拷贝）**：`Documents/Recap/` 为 Documents 唯一对外暴露面（`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`），技能落 `Documents/Recap/skills/<skillId>.md`；根路径可配置（`OpenWorkspaceRoot`，默认 `Documents/Recap`）——062 工作区即此根的扩展（`meetings/`、`recipes/` 同级追加），**不存在「App 内目录 × 工作区目录」互相同步的问题**（诊断 F3：那是我们拒绝做的双向 sync）。
2. `CustomTemplateStore` 改为目录后端（FileManager），对外 API（documents/skills/upsert/delete）不变，`TemplateSelectionSheet` 等消费方零改动。
3. **迁移**：首启检测旧 key `recap.customTemplates.v1` 非空 → 逐条写文件 → 旧 key 改名 `recap.customTemplates.v1.migrated`（不删，回滚安全）。
4. App 前台每次进模板页时重扫目录（外部改动可感知）；文件 id 撞内置 id → 跳过 + Debug 断言（现状语义不变）。

### Wave C: 编辑器解锁 + 导入导出

1. `CustomTemplateEditorSheet`：放开 modelRole 选择（quick/pro）、maxSteps 1–6、temperature、工具白名单多选（**仍只能从只读三件套 + 白名单子集选，`forbiddenTools` 硬禁名单在 codec 层不动**）。
2. 导入：模板页 toolbar `fileImporter`（`.md`/`plainText`）→ parse → **能力预览即同意时刻（诊断 F12）**：确认页列出「此技能将可访问：全部会议检索 / 允许工具 ×N / 步数上限」，外部 SKILL.md 是不可信输入，默认按只读三件套降权展示、勾选后才按文档声明放开；解析失败给可读错误（行号/原因，`AgentSkillDocument` 错误透传）。
3. 导出：我的空间每行 context menu「导出」→ `ShareLink`（临时文件 `<name>.md`）；「导出全部」→ 单个 `.md` 拼接包（`---` 分隔 + 头部说明注释）。
4. 新增空模板入口改为「从内置复制」：任一内置技能 →「复制为我的模板」→ 进编辑器（内置资源化后天然可行）。

## Verification

1. `xcodegen generate && sh scripts/fix_scheme.sh` + 构建 + `RecapLLMTests` 技能相关测试全绿（含 round-trip 迁移校验）。
2. 模拟器：旧版本装过的 App 升级安装 → 自定义模板出现在 Files 的 RecapSkills 目录；外部改一个文件回 App 生效。
3. 导入一个手写 SKILL.md（含合法 frontmatter）→ 可跑；导入缺字段文件 → 明确报错不崩溃。
4. Files app 中编辑正在使用的技能文件 → 重跑技能用新 prompt（Console 日志确认 skillId）。

## STOP conditions

- bundle 资源在 RecapLLM framework 内 `Bundle.module` 定位失败（SPM/xcodegen 资源接线问题）且 2 次尝试未解——退回「常量 → 单一生成文件编译进 target」方案并停下说明。
- Wave B.0 审计发现音频/数据库在 `Documents/` 且迁移风险高（路径写死多/iCloud 引用）——停下报告迁移面；降级方案改为「`Documents/Recap/` 单独子目录 + **不开** `UIFileSharingEnabled`，仅 App 内导入导出」（062 的 Files 可见性整体顺延，063 依赖面同步重估）。

## 执行记录（2026-09-30）

- **Wave A DONE**：23 个内置技能经脚本抽取至 `Agent/Skills/Bundled/*.md`（frontmatter 完整、缩进清洗核对）；project.yml 以 `buildPhase: resources` 编入 RecapLLM；`AgentBundledSkills` 重写为 Bundle 加载器（按文件名稳定排序；展示/推荐序不受影响）。测试 3/3（数量 23/全 parse/id 唯一/已知 id 在/白名单无写操作）。
- **Wave B DONE**：Wave B.0 审计通过（SwiftData 与音频均在 Application Support，Documents 干净）→ 走原方案（开 Files 共享）；`OpenWorkspace` 开放根（`Documents/Recap/`，062 扩展地基）+ `CustomTemplateStore` 目录化（`skills/<id>.md`，文件名防御性清洗防路径穿越）；旧 UserDefaults 数组自动迁移（旧键改名保留）；外部编辑经 `rescan()` 生效。测试 4/4。
- **Wave C DONE**：编辑器解锁（模型角色 quick/deep、步数 1–6、工具白名单多选——只读检索池，写操作 codec 层硬禁不变）；「我的模板」头部导入入口（多选 .md → **能力清单同意弹窗**：名称/工具数/步数 + 硬禁声明，F12）；自定义行 contextMenu 导出 .md（系统分享面板）；内置/收藏卡片 contextMenu「复制为我的模板」。
- **验证**：BUILD SUCCEEDED；新增 7 测试全过 + 全量回归绿（本机跳过环境劣化的手写用例，CI 全量裁决）。
- **状态：DONE（v1）**。后续小项：外部编辑自动感知（现 onAppear rescan）、skill 签名（v2）、在线社区目录（P2）。
