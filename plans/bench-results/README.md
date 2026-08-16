# 端侧模型评测战役（052 P1-2 / P1-3）— 测试集与结果归档

> 2026-08-16 建档。目标：为「双转正」补齐量化证据——FluidDiarizer vs SpeakerKit（DER）、
> SenseVoice 真机 CER（fp16 vs int8）、方言阈值标定。**所有结论必须落文件**，不再依赖口头/记忆数字
> （教训：「SenseVoice 长音频 7.81%」无产物留存，不可引用）。

## 一、测试集规范（真实中文会议，3–5 段）

| 编号 | 场景 | 时长 | 说话人 | 考察点 |
|---|---|---|---|---|
| S1 | 安静 1v1 访谈/1on1 | 10–15min | 2 | 基线 DER/CER |
| S2 | 会议室多人讨论 | 15–30min | 3–5 | 说话人数检出、聚类稳定性 |
| S3 | 快节奏抢话/插话 | 5–10min | 2–3 | chunk 边界切换、重叠段（FluidDiarizer minSpeechDuration=1s 是否丢短插话） |
| S4 | 长会议 | ≥60min | 2–4 | 长音频丢字（SenseVoice seam）、内存/热 |
| S5 | 方言/口音（四川话等） | 5–10min | 1–2 | 方言阈值 0.4 标定 + 方言重转验证 |

要求：真实录音（非朗读）；每段准备——
- `S<N>.m4a`/`wav` 原始音频；
- `S<N>.ref.txt` 人工逐字稿（算 CER）；
- `S<N>.ref.rttm` 说话人时间轴（算 DER；标注见下）。

## 二、RTTM 标注规范

格式（pyannote 标准，App 内 DERScorer 解析第 4/5/8 列）：

```
SPEAKER S1 1 0.00 3.20 <NA> <NA> spk1 <NA> <NA>
SPEAKER S1 1 3.21 5.80 <NA> <NA> spk2 <NA> <NA>
```

- 时间单位秒，`start` + `dur`；
- 说话人 ID 全段一致（spk1/spk2/…），**同一人跨段必须同 ID**（否则 DER 虚高）；
- 静音不标；抢话重叠可多行同时间窗（DERScorer 按对共现累计，两引擎同口径公平）；
- 标注工具不限（Audacity 打标记导出、手写均可），每 15–30 分钟音频约 15–30 分钟工时。

## 三、评测流程（RecapASRBench，真机）

1. Xcode 打开 `RecapASRBench.xcodeproj`，选真机跑；
2. 选音频 → 勾选引擎（diarizer 对比勾 `fluidDiarizer`；ASR 勾 `fluidSenseVoice`）；
3. 粘贴 `S<N>.ref.txt`（CER）与 `S<N>.ref.rttm`（DER）→ 开始评测；
4. 结果行显示 CER/DER/RTFx/内存峰值/热档/掉电；
5. **截图 + 手抄关键数字** 归档到本目录（见下）。

### P1-3 int8 A/B

`FluidAudioEngine`（Bench 侧）构造处把 precision 换 `.int8` 再跑一轮 S1–S4。
记录：ANE 编译是否成功（失败会 NaN/崩溃，正是要测的「部分机型」面）、CER 差、内存峰值差。
通过标准：编译成功 + CER 差 ≤0.5pt + 内存降 → 建议主 App 默认切 int8（225MB）。

## 四、归档约定

- 本目录每战役一文件：`<日期>-<主题>.md`（如 `2026-08-20-diarizer-der.md`）；
- 内容：环境（机型/OS/电量/温度起始）、每段每引擎的完整数字表、结论与建议（是否默认开/转正 Phase 2）；
- 原始记录截图可放同目录 `assets/`；
- **没有落文件的数字不进决策**。

## 五、判定门槛（052 §3.2 Phase 2）

- FluidDiarizer 转正默认开：S1–S4 加权 DER **不劣于 SpeakerKit +2pt** 且无崩溃/超时；
- SenseVoice（自动重转）默认开：S1/S2/S4 CER ≤ SpeechAnalyzer LIVE 稿（否则「升级」名不副实）；
- 方言阈值：S5 + 普通话对照组，误触发率（普通话被判方言）<10% 且漏检率可接受。
