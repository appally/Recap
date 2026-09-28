# 开放工作区格式（Open Workspace Schema）— 占位骨架

> 状态：**DRAFT（plan 062 定稿）**。本页是开放格式的对外契约占位：一旦公开，目录结构即 API，
> 破坏性变更须开 v2 并保留 v1 导入器。实现顺序见 plans/060（开放根目录 + skills/）→ 062（meetings/ 增量镜像 + diff 回导）。

## 根目录布局（060 起）

```
<OpenWorkspaceRoot>/            # 默认 Documents/Recap/，路径可配置
├── skills/                     # plan 060：用户技能 = SKILL.md 文件（<skillId>.md）
├── recipes/                    # plan 059：供应商配方 JSON（不含 Key）
└── meetings/                   # plan 062：会议镜像（占位）
    └── <meetingID>/
        ├── meeting.json        # 元数据（标题/时间/时长/语言/地点）
        ├── transcript.md       # 带说话人逐字稿（[mm:ss] 名字：文本）
        ├── minutes-v*.md       # 纪要版本（导入时 version+1，见 plan 030 纪律）
        ├── todos.json          # 结构化待办（含 evidenceQuote 溯源）
        └── audio.m4a           # 音频（默认包含，可关闭；声纹永不出现于此）
```

## 原则

1. **配置双向、会议单向**：skills/recipes 可被外部编辑后回导（upsert）；meetings/ 导出为镜像、外部修改经「显式 diff 导入」生效（纪要 → 新版本）。
2. **manifest 增量**：根下 `workspace-manifest.json` 记录文件 hash/mtime，App 前台 + BGAppRefreshTask 增量同步，不承诺实时。
3. **永不入工作区**：任何 API Key、声纹特征、Keychain 内容。
4. **语义化版本**：`schemaVersion` 字段贯穿；v1 期间允许增字段（消费方须容忍未知键），删改字段开 v2。
