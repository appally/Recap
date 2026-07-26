# Plan 039: AxiiDiarization 评估与替换 SpeakerKit

> **Executor instructions**: 本计划是 **POC-gated**——效果/性能两未知必须先用真实中文会议在 iPhone 上钉死，再决定是否替换。Follow step by step；honor STOP conditions。
>
> **Drift check (run first)**: 工作区无 `.git`。确认 live code 仍匹配：
> - `RecapApp/Modules/RecapASR/Diarization/DiarizationService.swift` 已有 `protocol MeetingDiarizer: Sendable`（`prepare`/`diarize`/`unload`）
> - `DiarizationService.diarizeMeeting(... diarizer: any MeetingDiarizer = SpeakerKitDiarizer.shared ...)`
> - `SpeakerKitDiarizer: MeetingDiarizer`；`prepare()` 无参（已去掉 modelFolder）
> - `MeetingSession.diarizeFromDisk` 调 `DiarizationService.diarizeMeeting(...)` 不传 diarizer（走 SpeakerKit 默认）
> - `SpeakerAlignerTests.testDiarizationServiceInjectsEngine` 用假引擎注入并通过
>
> On mismatch, STOP（说明 038/本计划前提已漂移）。

## Status

- **Priority**: P2（评估型；POC 通过才进替换，否则保留 SpeakerKit）
- **Effort**: L（POC：模型转换 + bench 接入 + 真机双跑；替换本身 S，因抽象已落地）
- **Risk**: MED-HIGH（见下；iPhone 性能/中文质量双未知；441MB 模型；早熟库）
- **Depends on**: 无硬依赖；替换路径已由本评估预先抽好 `MeetingDiarizer` 协议（无代码冲突）
- **Category**: direction（分离引擎升级）+ perf
- **Planned at**: workspace snapshot 2026-07-26（无 git SHA）
- **Issue**: （未发布）

## Why this matters

当前会后分离用 **SpeakerKit（pyannote community-1 CoreML）**——批处理、每场独立标 spk0/spk1、无跨场身份。**AxiiDiarization** 提供两项 SpeakerKit 结构性做不到的能力，恰好命中路线图：

| 能力 | SpeakerKit | AxiiDiarization | 命中 Recap |
|---|---|---|---|
| 会后批处理 | ✅ | ✅ `pipeline.run(audio:)` | 现状 |
| **流式/会中分离** | ❌ | ✅ `DiarizationSession.addAudio/process/finalize` | Plan 033 会中观察者（LIVE speaker 标签） |
| **跨录音说话人身份** | ❌ | ✅ `SpeakerProfile`+`knownSpeakers`+`enrichedEmbeddings`（AMI 94.8%） | P3 人物记忆 / "上次和这家客户" |

**但"效果更好、性能更好"目前无证据**——这是 POC 的全部理由。

核实结论（执行前勿假设）：

| 事实 | 证据 / 来源 |
|---|---|
| Axii **5.3% DER @ VoxConverse**（10s 窗） | README；VoxConverse 偏干净 |
| SpeakerKit pyannote community-1 **AMI DER 10.6%** | 本仓 `端侧ASR选型指南.md` §1.2 |
| **两数据集不可比**；中文会议 DER **两者都没发** | VoxConverse 同系统 DER 普遍低于 AMI |
| Axii **~400× 实时**，但未注明芯片（几乎可断定 Mac M 系） | README；iPhone RTF **未知** |
| Sortformer 模型 **441MB** + ResNet34 25MB，CoreML | README；App Store 蜂窝 200MB 限 → 必须按需下载 |
| 模型 **不附带、不可下载**，需自行 Python/NeMo 转换 | README（`nemo_toolkit[asr]`+`coremltools`） |
| 早熟：1★、18 commits、**无 Sendable/Swift6 文档** | GitHub；Recap 是 Swift 6 strict，需自建串行 actor 包一层（类比 argmax #661 CoreML 共享 E5RT scratch 崩坑） |
| license 非红线（用户决策） | MIT 代码 + Apache-2.0 WeSpeaker + **NVIDIA OML Sortformer**（需登记/知情） |

## POC（gating；场地 = RecapASRBench，device-only，已有多引擎基础设施）

### Step 1 — 转模型（Mac/Python，一次性）
```
python3 -m venv .venv_nemo && .venv_nemo/bin/pip install nemo_toolkit[asr] coremltools
# 产 sortformer_4spk_v21.mlpackage (441MB) + wespeaker_resnet34.mlpackage (25MB)
```
STOP：转换失败 / 模型在 Mac 推理结果异常 → 不进 Step 2。

### Step 2 — bench 接入
- RecapASRBench（`RecapASRBench.xcworkspace`，**仅 device**，见 [[recap-ios-build-constraints]]）加 AxiiDiarization SPM 依赖。
- 写 `AxiiDiarizerBench`：包 `DiarizationPipeline` 进串行 actor（防 CoreML 并发崩），实现与本仓 `MeetingDiarizer` 同构（或直接复用协议）。
- 模型放 bench 资源（POC 阶段不涉包体积/分发）。

### Step 3 — 真实中文会议双跑
- 语料：**5–10 段 Recap 自有真实中文会议录音**（有标注说话人最好；无则人工抽查归属）。
- 同一段分别跑 SpeakerKit 与 Axii，记录四项：说话人归属准确率（或 DER）/ iPhone RTF / 峰值内存 / 30min `thermalState` 曲线。

### Step 4 — 通过线（全部满足才替换）
- 中文归属准确率 ≥ SpeakerKit（或差 ≤2pt）
- iPhone **RTF ≤ 5× 实时**（30min 会议 ≤6min 分离完）
- 峰值内存 < 1GB（三模型同载 1–1.5GB OOM 风险）
- 热节流不劣于 SpeakerKit

**任一不满足 → STOP，保留 SpeakerKit**，记录结果；待 Axii 成熟或出中文微调权重再议。

## 替换设计（POC 通过则就绪；抽象已落地，改动局部化）

本评估已预先抽出 `MeetingDiarizer` 协议，替换 = 新增一个实现 + 改默认参数：

```swift
// RecapApp/Modules/RecapASR/Diarization/DiarizationService.swift（现状）
public static func diarizeMeeting(
    ...
    diarizer: any MeetingDiarizer = SpeakerKitDiarizer.shared,  // ← 改这行即切 Axii
    ...
)
```

```swift
// 新增 AxiiDiarizer.swift（POC 后）
public actor AxiiDiarizer: MeetingDiarizer {
    public static let shared = AxiiDiarizer()
    private var pipeline: DiarizationPipeline?
    public func prepare() async throws { /* 加载 mlpackage（首次按需下载到 Application Support） */ }
    public func diarize(samples:numberOfSpeakers:progress:) async throws -> [SpeakerTimelineSegment] {
        let res = try pipeline.run(audio: samples)
        return res.segments.map { SpeakerTimelineSegment(speakerIndex: Int($0.speaker.label) ?? 0,
                                                          startSeconds: $0.start, endSeconds: $0.end) }
    }
    public func unload() async { pipeline = nil }
}
```

`SpeakerAligner` / `MeetingSession` / UI **全不动**——`testDiarizationServiceInjectsEngine` 已证明对齐层引擎无关。

**模型分发**（替换时必做）：441MB 不能进包；仿 `端侧ASR指南.md` §4.6 自建 CDN/对象存储 + 首次按需下载到 Application Support（FluidAudio 模型分发同套机制可复用）。

## 流式 + 跨场（替换后的新能力，单独计划，不在本计划）

- **流式**：`LiveDiarizer` 包 `DiarizationSession`，挂录音 tap 与 ASR 并行 → LIVE speaker 标签 → 喂 Plan 033。注意与「calm UX」边界协调（标签属内容层可接受）。
- **跨场身份**：SwiftData 存 `SpeakerProfile(embeddings)`，`createSession(knownSpeakers:)` + `enrichedEmbeddings` 回写 → 人物记忆。

## Acceptance（POC 完成 = 本计划完成）

- [ ] Step 1 模型转换成功并在 Mac 推理正常
- [ ] Step 2 AxiiDiarizerBench 在 iPhone 真机跑通
- [ ] Step 3 中文会议双跑数据落表（准确率/RTF/内存/热）
- [ ] Step 4 通过线判定（过/不过），结论写回本计划 Status
- [ ] 若过：`AxiiDiarizer` 实现 + 默认参数切换 + 模型分发；全量测试绿（含 `testDiarizationServiceInjectsEngine`）

## Decisions for reviewer

1. **是否启动 POC**：需要 Mac + Python 环境 + 真机 + 5–10 段中文录音。你确认即可推进 Step 1–3。
2. **NVIDIA OML Sortformer**：商用需登记；license 非红线但要法务知情签字——在 POC 启动前确认。
3. **若 POC 不过**：保留 SpeakerKit；流式/跨场能力改由"会后分离 + LLM 归并说话人"等替代路径满足（ weaker 但无新依赖）。
