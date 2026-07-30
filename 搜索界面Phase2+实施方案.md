# 搜索界面 Phase 2+ 实施方案

> 状态：方案拟定 · 待评审决定起始项
> 日期：2026-07-29
> 前置：Phase 0/1 已落地（`搜索界面设计方案.md` / `.claude/plans/linear-wiggling-quokka.md`）
> 视角：用户体验（搜索完整链路 = 想起 → 找到 → 直达 → 回顾）

---

## 1. Phase 1 落地后的体验断点诊断

Phase 1 让用户能"搜到那场会"。但搜索的完整体验在"直达"和"回顾"上仍有断点：

### 断点 1：直达断裂（最痛）
用户搜「报价」，卡片写着「张总：这个报价我们内部再对一下 12:03」。点进去却被丢到「总结」Tab，要自己在转写里翻到 12:03。
→ **搜索承诺了"定位"，却只交付了"找到会议"。这是搜索体验的核心缺失**。

### 断点 2：召回缺口（Phase 1 遗漏）
- **纯笔记命中的会议被丢弃**：`collectHits`（`RecapWorkspaceIndex.swift`）只收集 title/summary/transcript/actionItem 四类，**没有收集 notes**。ranker 虽用 `notes` 召回了会议，但 `collectHits` 对纯笔记命中会议返回空 → `guard !hits.isEmpty` 过滤掉。即 Phase 1 实际搜不到"只命中笔记正文"的会议。
- **纯转写命中的会议被漏掉**：ranker 只用快字段（标题/纪要/待办/笔记），不含转写；`searchMeetings` 注释禁止跨会议解 segments。标题/纪要/待办/笔记都不命中、只转写命中的会议不会被召回。

### 断点 3：结果过载
搜「报价」命中 15 场，无法缩小到「上个月」或「张总参与的」。结果多了等于没找到（Hick's law）。

---

## 2. Phase 2+ 优先级矩阵（UX 价值 × 可行性）

| 项 | UX 价值 | 可行性 | 优先级 | 依据 |
|---|---|---|---|---|
| A. 命中片段精确跳转 | ★★★★★ | ★★★★ | **P0** | `jumpToTranscript` 已存在（MeetingNoteView:1836），打通外部入参即可；搜索的"最后一公里" |
| B. 笔记纳入 + 修 collectHits | ★★★★ | ★★★★★ | **P0** | 修 Phase 1 召回遗漏 + 找回产出物（邮件/周报），collectHits 加 notes 极简 |
| C. 纯转写召回 | ★★★★ | ★★★ | **P1** | 召回完整性，性能待实测（量级小可直接全量解） |
| D. 克制筛选（时间+待办） | ★★★ | ★★★★ | **P1** | 结果过载补救，只做最常用维度，不做复杂 facet |
| E. Ask 深度搜兜底 | ★★★ | ★★★★★ | **P2** | 复用现有 Agent，无结果时引导 |
| F. 跨会议主题聚合 | ★★ | ★★★ | **P3** | 低频高价值，结果重组 |
| G. 语义/向量搜索 | ★★ | ★★ | **P3/不做** | 当前 ROI 低，端侧重、云端隐私 |

---

## 3. P0 实施方案（修断点 1+2，体验闭环）

### P0-1：命中片段精确跳转

**UX 设计**
- 卡片整体点击 → 进详情页默认「总结」Tab（概览，保留 Phase 1 行为）。
- **命中片段行**（转写/待办/笔记）→ 独立可点击，跳**精确位置**：
  - 转写 hit → 跳转写 Tab + 滚动到 `timeAnchor` 秒 + 自动播放。
  - 待办 hit → 跳转写 Tab 对应 `timeAnchor`（待办的 evidenceQuote 原话位置）。
  - 笔记 hit → 跳笔记 Tab + 选中该篇笔记。
- 解决点击冲突：片段行各自包 `NavigationLink(value: .meetingAt(...))`；卡片标题区仍是 `NavigationLink(value: .meeting)`。即卡片内多个入口，各跳各的。

**技术实现**（代码依据已核对）
1. **`MeetingRoute` 加 case**（`MeetingListView.swift:7`）：
   ```swift
   case meetingAt(UUID, scrollStart: Double?, noteTarget: NoteTarget?)
   ```
   - `NoteTarget` 已 `public Sendable/Hashable`（`NoteIndex.swift:4`），`Double` Hashable → `MeetingRoute` 自动合成 Hashable 不受影响。
   - **不需把 `ReviewTab` 提 public**（关键简化）：initialTab 由 scrollStart/noteTarget 在 `destination(for:)` 里派生。
2. **`destination(for:)` 扩 case**（`MeetingListView.swift:446`）：
   ```swift
   case .meetingAt(let id, let scrollStart, let noteTarget):
       if let meeting = meetings.first(where: { $0.id == id }) {
           MeetingNoteView(meeting: meeting,
                           initialScrollStart: scrollStart,
                           initialNoteTarget: noteTarget) {
               if !path.isEmpty { path.removeLast() }
           }
       } else { Text("会议不存在")... }
   ```
3. **`MeetingNoteView.init` 扩参**（`MeetingNoteView.swift:78`）：
   ```swift
   public init(meeting: Meeting,
               initialScrollStart: Double? = nil,
               initialNoteTarget: NoteTarget? = nil,
               onDismiss: @escaping () -> Void = {})
   ```
   init 里灌 `@State`：
   - `initialNoteTarget != nil` → `selectedNote = initialNoteTarget` + `reviewTab = .note`
   - `initialScrollStart != nil` → `pendingScrollStart = initialScrollStart` + `reviewTab = .transcript`
   - 否则保持默认 `.summary`
4. **坑1 修复**（`pendingScrollStart` 不首帧触发）：`transcriptBody` 的 `ScrollViewReader` 内层加 `.onAppear { if let s = pendingScrollStart { scrollTranscript(proxy: proxy, startSeconds: s) } }`，与现有两个 `.onChange`（`MeetingNoteView.swift:979`）并列。
5. **坑2 规避**：init 里 `reviewTab` 与 `selectedNote` 成对设置（见上）。
6. **坑3 边界**：MVP `initialNoteTarget` 只接受 `.summary / .note(id)`；`.researchDraft/.researchTask` 走 sheet 不适合 inline 跳转，命中不产生这两类跳转。
7. **SearchView 改造**（`SearchView.swift` `MeetingSearchCard`）：片段行从静态展示改为 `NavigationLink`，按 hit.kind 分流跳转目标（见 P0-2 后的命中类型表）。

### P0-2：笔记纳入 UI + 修 collectHits 召回遗漏

**技术实现**
1. **`SearchHitKind` 加 `.note`**（`WorkspaceSearchTypes.swift:8`），label「笔记」。
2. **`SearchHit` 加 `noteTarget: NoteTarget?`**（`WorkspaceSearchTypes.swift`，与 `timeAnchor` 平行，供笔记跳转；其它 hit 为 nil）。
3. **`collectHits` 加 notes 收集**（`RecapWorkspaceIndex.swift`）：遍历 `meeting.outputs.filter{ $0.kind == .note }.compactMap{ $0.notePayload }`，对 title+body 命中的，生成 `SearchHit(kind: .note, snippet: ..., noteTarget: .note(output.id), score: 3)`。需保留 output.id 以构造 NoteTarget。
4. **rankerFields 的 notes 来源与 collectHits 一致**（已含 title+body，无需改 ranker）。

**命中类型 → 跳转目标映射**（SearchView 片段行）

| hit.kind | 跳转 | MeetingRoute |
|---|---|---|
| transcript | 转写 Tab + timeAnchor 播放 | `.meetingAt(id, scrollStart: hit.timeAnchor, noteTarget: nil)` |
| actionItem | 转写 Tab + timeAnchor（待办原话） | `.meetingAt(id, scrollStart: hit.timeAnchor, noteTarget: nil)` |
| note | 笔记 Tab + 选中该篇 | `.meetingAt(id, scrollStart: nil, noteTarget: hit.noteTarget)` |
| summary | 总结 Tab | `.meeting(id)`（默认即可） |
| title | 总结 Tab | `.meeting(id)` |

---

## 4. P1 实施方案（补召回 + 筛选）

### P1-1：纯转写召回
- `searchForUI` 对**非 ranker 命中场**也做 `SearchTranscriptTool.search`（全量解 segments）。
- **性能闸门**：先实测 50 场全量解 segments 耗时。sub-300ms 则放开全量；否则限"最近 N 场"或留 Phase 3 扁平索引表。
- UX：无感（召回更全，用户只是"搜得到了"）。

### P1-2：克制筛选
- 顶部结果计数行旁加筛选 chips：**时间**（最近一周 / 一月 / 全部）+ **仅看待办**（J2 场景）。
- **不做**复杂 facet 面板（说话人/地点/产出类型留 Phase 3）。
- UX：结果数 > 阈值（如 8 场）时显示筛选条；少时隐藏（克制，避免低结果时还显示一堆筛选）。

---

## 5. P2/P3 展望

- **P2 · Ask 深度搜兜底**：无结果态加「用 Ask 深度搜」按钮，复用 `AgentInvokeSheet` / Agent 能力。关键词召回不到时引导 AI 问答（复用现有 `search_meetings`/`search_transcript` 工具链）。
- **P3 · 跨会议主题聚合**：结果按主题/时间线聚合视图（J5「这个月关于定价的所有讨论」），是结果的组织方式而非新搜索。
- **P3 · 语义/向量搜索**：端侧 CoreML embedding 或云端。当前关键词 + 中文 2-gram 召回已覆盖大部分，ROI 低，量级与需求增长后再评估。
- **明确不做**：FTS5（SwiftData 私有 schema 风险）。

---

## 6. 关键决策点（待评审）

1. **起始项**：P0（精确跳转 + 笔记纳入）是否立即实施？-- 推荐：是，修断点 1+2 是体验闭环，且 P0-2 顺手修 Phase 1 召回遗漏。
2. **筛选维度**（P1）：只做「时间 + 仅看待办」（推荐）还是加「说话人」？
3. **纯转写召回**（P1）：先实测全量性能再定，还是直接上扁平索引表？-- 推荐：先实测，量级小则全量解更简单。

---

## 7. P0 改动清单（文件级）

| 文件 | 改动 |
|---|---|
| `RecapModels/NoteIndex.swift` | 无改（NoteTarget 已 public） |
| `RecapUI/MeetingListView.swift` | `MeetingRoute` 加 `meetingAt`；`destination(for:)` 扩 case |
| `RecapUI/MeetingNoteView.swift` | init 扩 `initialScrollStart/initialNoteTarget`；transcriptBody 内层 `.onAppear` 补首帧滚动 |
| `RecapLLM/WorkspaceSearchTypes.swift` | `SearchHitKind` 加 `.note`；`SearchHit` 加 `noteTarget: NoteTarget?` |
| `RecapPersistence/RecapWorkspaceIndex.swift` | `collectHits` 加 notes 收集（修召回遗漏） |
| `RecapUI/SearchView.swift` | `MeetingSearchCard` 片段行改 NavigationLink，按 kind 分流跳转 |
| `Tests/RecapLLMTests/WorkspaceSearchTests.swift` | 补 notes 命中 + noteTarget 测试 |
