# 发布流程（RELEASES）

> 单人项目纪律：每次发布 60 分钟内完成全部步骤，任何一步卡住就停下来修流程再发。

## 版本与 tag

- tag：`v<major>.<minor>.<patch>`（如 `v0.9.0`）；开源首版 `v0.9.0-oss`。
- GitHub Release 与 App Store 构建号一一对应：`v0.9.0` ↔ CFBundleVersion 递增后的那个 TestFlight/App Store 版本。
- CHANGELOG：Release notes 即 changelog（不维护单独文件），格式：`新增 / 修复 / 开放化 / 已知问题`。

## 步骤清单

1. `plans/README.md` 相关 plan 状态收口（DONE/PARTIAL + 日期 + 验证证据）。
2. 本地验证三件套：
   - `cd cloud && npx vitest run && npm run typecheck`
   - iOS 构建 + 单测（**具体模拟器 destination**，见 README）
   - 涉及网关时 `wrangler deploy` + curl E2E（/health → /v1/issue → /v1/relay 401/补全）
3. `git tag -a vX.Y.Z -m "..."` → push tag → GitHub Release（贴 notes）。
4. App Store：xcodebuild archive → 上传 → TestFlight 冒烟（录音→纪要→导出三步）→ 提审。
5. 公告（可选）：README 徽章更新、社区渠道（ discussions 置顶）。

## 回滚

- 网关：`wrangler rollback`（Workers 版本历史）。
- App：TestFlight 分阶段；App Store 走加急审核修复流程。
- 开放工作区 schema：按 `docs/schema.md` 的版本纪律（v1 容忍新增字段，删改开 v2）。
