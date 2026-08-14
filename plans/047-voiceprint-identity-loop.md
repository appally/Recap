# Plan 047: 声纹身份产品化闭环——纠错写回画廊 / 跨会议「上次见 TA」/ 重叠说话标记

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P0（2026-08-14 产品调研：说话人「分得出人分不清谁是谁」是 Plaud 差评密度最高的问题，
  通义听悟官方承认做不到，飞书 2025 才上线；我们声纹画廊架构已跑通，缺的是纠错闭环产品化）
- **Effort**: M
- **Risk**: MEDIUM（spk 索引重排、误纠错污染终身身份）
- **Depends on**: none
- **Category**: feature

## Why this matters

声纹跨录音身份是我们的头号差异化资产，但目前：**没有任何说话人改名/换人 UI**（纠错链路纯空白）；
名字保留机制以不稳定的 `spkN` 索引为 key（重跑分离后可能贴错人）；「上次见 TA」数据已具备
（每场 Meeting speakers blob 含 voiceprintId）但无查询入口。三件事补齐后，「认识你的常客」
从技术能力变成用户可感知的产品。

## Current state（勘察结论，2026-08-14 核实）

### 两层 Speaker 模型

- **会议内** `RecapModels/Speaker.swift:4`：`{ id: "spk\(Int)", name, colorIndex, voiceprintId: String? }`，
  JSON blob 存 `Meeting.speakersData`。`voiceprintId` 是 FluidAudio 画廊 id（SpeakerKit 路径/旧数据为 nil）。
- **跨会议** FluidAudio `Speaker`（`SpeakerTypes.swift:6`）：256 维 currentEmbedding、
  `mergeWith(_:keepName:)`（:168）、`rawEmbeddings` FIFO 50、`isPermanent`。
- 画廊：`VoiceprintGallery.swift` 单例，`Application Support/VoiceprintGallery.json`，
  已有 `save/upsert/markAsMe/enrollAsMe/clearAll`；**缺 rename/merge**。

### 名字保留的 key 缺陷（本计划必须修）

`DiarizationService.diarizeMeeting` 的 `preserveSpeakerNames` → nameMap 以 **`Speaker.id`
（"spkN"，不稳定）** 为 key（`MeetingSession.swift:656`、`DiarizationService.swift:82`）。
`makeSpeakers` 按时间轴首次出现顺序生成 spk 索引（`SpeakerAligner.swift:76`）——重跑后 index
重排，纠错的名字会贴错人。**所有终身写回必须以 voiceprintId 为 key**。

### 匹配链路与现状

- 会后分离主入口：`scheduleDiarizationIfNeeded`（MeetingSession:1418）→ `FluidDiarizer.diarize`
  → consent 门内 `initializeKnownSpeakers(画廊快照)` → `SpeakerAligner.assignSpeakers`
  （每段取时间重叠最长者，单标签）→ `VoiceprintGallery.shared.save(...)` 写回演化。
- 改名：**无 UI**。`SpeakerBlockView.onMarkMe`（Components.swift:115-130）是说话人名唯一动作。
- 重叠说话：引擎层已产出 overlap 双段（FluidAudio threshold 0.15），但
  `bestSpeakerIndex`（SpeakerAligner.swift:85）赢家通吃，次优信息被丢弃。
- 轨迹：`Meeting.speakersData` 每场含 voiceprintId，FetchDescriptor 全量 + 内存过滤即可查
  「这个 voiceprintId 出现在哪些会议」（无谓词查询，会议量级可接受）。

## Implementation

### Wave A: 画廊纠错 API + voiceprintId-keyed 名字保留（数据层，先行）

1. `VoiceprintGallery` 新增：
   - `rename(voiceprintId: String, name: String)`：贴名（不置 isPermanent——改名≠「我」）。
   - `merge(sourceId: String, intoId: String, keepName: Bool)`：值拷贝上调 FluidAudio
     `Speaker.mergeWith`，upsert 目标 + 从 storage 删 source。
2. **名字保留改 key**：`DiarizationService.diarizeMeeting` 的 nameMap 改为
   `[voiceprintId: name]`（从 `preserveSpeakerNames` 提取 voiceprintId 非空者），
   `SpeakerAligner.makeSpeakers` 消费时优先按 voiceprintId 贴名，无 voiceprintId 的旧数据
   保留 spkN 回退路径。**这是纠错终身生效的根：纠错后的名字只有以 voiceprintId 为 key 才能在
   重跑分离后正确重放。**

### Wave B: 纠错 UI（SpeakerDetailSheet）

新文件 `RecapUI/SpeakerDetailSheet.swift`，入口 = REVIEW 态 `SpeakerBlockView` 说话人名
contextMenu（长按）→「查看/纠正发言人」。Sheet 内容：

1. **重命名**：TextField → 同步三处——画廊 `rename(voiceprintId:)`（有 voiceprintId 时）+
   本场 `meeting.speakers` 对应条目 name + save。无 voiceprintId（SpeakerKit 路径）只改本场。
2. **合并**：「与另一位发言人合并」picker → 画廊 `merge(sourceId:intoId:)` + 本场段级
   `segment.speakerId` 从 src spk id 重映射到目标 spk id、删除 src Speaker 条目。
3. **上次见 TA**（voiceprintId 非空时）：`VoiceprintHistory.meetingsContaining(voiceprintId:context:)`
   （新纯函数，FetchDescriptor<Meeting> sortDescriptor(startedAt) + 内存过滤 speakers blob）
   → 展示「上次见 TA：7月28日《客户拜访》」+ 最近 3 场列表，可点击跳转。

### Wave C: 重叠说话标记（对齐层小改）

- `SpeakerAligner.bestSpeakerIndex` 返回 `(primary, secondaryOverlapRatio)`；次优/最优重叠比
  > 0.8 且 speaker 不同 → `TranscriptSegment.isOverlapped: Bool?`（Codable 可选新增，默认 nil
  向后兼容）。
- `SpeakerBlockView` 该行说话人名旁加极简标记（如 `⌁` 或双头像色点），**不新增文字噪音**
  （遵守克制美学 memory：recap-motion-design-stance）。

## Verification

1. `xcodegen generate` + 全量构建（命令见 README「How to execute」）。
2. 单测（放 SpeakerAlignerTests 同 target）：
   - nameMap 按 voiceprintId 贴名（构造两个 speaker，打乱 spk 索引顺序，断言名字跟人走）；
   - merge 后本场段 speakerId 重映射、src 条目删除；
   - isOverlapped 判定（构造 80% 重叠双说话人时间轴）。
3. VoiceprintGallery 单测：rename/merge 后 json 读写一致、merge 删 source。
4. 真机/模拟器手测：标记我 → 第二场录音认出「我」→ 第三场改名 → 重跑分离 → 名字仍正确。

## STOP conditions

- `SpeakerAligner` / `DiarizationService` 现状摘录与实际代码不符（drift）→ 停，重读。
- FluidAudio `Speaker.mergeWith` 行为与勘察不符（如 rawEmbeddings 溢出丢弃语义）→ 停，读
  checkout 源码确认后再写 merge。
- 轨迹查询在 >500 场会议的库上解码明显卡顿（>300ms 主线程）→ 停，改为后台线程解码。

## Considered and rejected

- **冻结 permanent Speaker 的 EMA 更新**（防误命中永久漂移「我」的声纹）：`updateExistingSpeaker`
  在 FluidAudio 依赖包内，App 层不可改；需要 fork。另案记录，本批不做。
- **用纠错段的音频 embedding 反哺画廊**：`mapTimeline` 已丢弃段级 embedding
  （FluidDiarizer.swift:202 注释「Phase 2 起用」），需要引擎侧透传，非最小改动。拒。
- **未同意声纹期间的追溯补纠错**：consent 前的分离不读不写画廊，历史不可追溯——合规语义
  正确，不改。
- **删除单个画廊说话人**：`clearAll` 一刀切是合规撤回语义；单人删除与「撤回=全删」口径冲突，
  待 PIPL 口径确认后另案。
- **改名入口用弹窗 alert**：与「平静美学」不符，用 sheet（对齐 SpeakerPickerSheet 形态）。
- **VoiceprintGallery.json 排除 iCloud 备份**：与「用户不可再生数据保留备份」哲学冲突
  （勘察风险 6），加密存储另案，不在本批。
