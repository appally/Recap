# POC：FluidAudio 端侧重转写 + LIVE VAD 真机验收清单

> 配套实现 plan：`~/.claude/plans/lively-splashing-alpaca.md`
> 选型依据：`端侧ASR选型与iOS落地工程指南.md`
> 代码已集成但 **feature flag 默认关**（`asr.fluidRetranscribeEnabled` / `asr.vadGateEnabled`），本清单全绿后才打开。

## 真机快速验证（5 分钟体验）

> ⚠️ **必须真机**：SenseVoice fp16 走 ANE，模拟器无 ANE → NaN 失败。模拟器只能验③（LLM 润色）。

1. **配 LLM 密钥**：设置 → LLM → 配 DeepSeek（③ 自动润色 + 纪要都要）。
2. **开 flag + 下模型**：设置 → 转写引擎 →「端侧高保真（实验）」：
   - 打开「会后端侧高保真重转」
   - 点「预下载端侧 ASR 模型」（~225MB，走 hf-mirror，等「端侧模型已就绪」）
3. **开一场会**：正常录音（LIVE 仍用 SpeechAnalyzer），说几句中英混排的话，结束。
4. **触发端侧重转**：纪要页「更多」菜单 →「端侧高保真重转」→ 选 SenseVoice。
   - 重转后逐字稿变准（中英混排、标点、错别字）。
   - **联动**：重转完成自动接 LLM 润色（双行：原话 + 润色）。
5. **对比**：重转前后逐字稿对照。

**进 REVIEW 自动行为**（无需手动）：有 DeepSeek key → 逐字稿自动润色（双行）；有本地录音 → 自动说话人分离。

## 为什么必须 POC
FluidAudio 是早期项目（v0.15.x 几乎周发版），所有中文 CER/RTF/内存/发热数据都跑在 Mac M5 Pro，
**iPhone 真机数据完全缺失，不能外推**。已知 iOS 坑：#661 并发崩（已由 `CoreMLInferenceGate` 兜底）、
#758/#746/#803 长音频丢字、#738 iOS27 后台 ANE 锁定。

## 环境
- 机型：iPhone 15 Pro / 16 Pro（A17 Pro+，Apple Intelligence）
- 音频：**真实中文会议录音**（非 AISHELL 朗读），30 / 60 分钟各一段，含中英混读、多人、远场
- 模型：SenseVoice fp16（默认）、Paraformer fp16 对照；hf-mirror 镜像已配

## 验收项

### 1. 中文准确率（最关键）
- [ ] 真实会议 CER baseline（对比 SpeechAnalyzer 同段录音）。预期端侧 FluidAudio 明显更优。
- [ ] 中英混读段落：SenseVoice 是否正确保留英文（不强行翻译/音译）。
- [ ] 标点：句末标点是否齐全。
- [ ] 人名/术语：错误率（FluidAudio 中文无热词接口，本期未接纠错——记录 baseline 痛点）。

### 2. 性能
- [ ] 30 分钟音频重转 RTF（能否 < 1× 实时，即 30 分钟内完成）。
- [ ] 30 分钟持续转写 RTF 衰退曲线（有无越跑越慢）。
- [ ] 首模型下载时长（hf-mirror）+ 冷加载时长（首次 `prepare`）。

### 3. 内存
- [ ] 三模型同驻峰值（SenseVoice + SpeakerKit pyannote）：是否 OOM（选型文档评估 1–1.5GB）。
- [ ] 长音频内存是否随时长线性增长（不应—— FluidAudio 支持流式读盘）。

### 4. 发热
- [ ] 30 分钟重转 `thermalState` 变化曲线（nominal→fair→serious？）。
- [ ] `ThermalGate` 在 serious/critical 是否正确延后重转/diarize。

### 5. 长音频丢字（#758/#746/#803）
- [ ] 30+ 分钟真实会议**听校对**：28s chunk 边界是否丢字/粘字/多语漂移。
- [ ] 前导静音整窗丢字是否复现。

### 6. #661 并发（gate 验证）
- [ ] **重转写 + diarization 时间窗重叠**：进 REVIEW 自动 diarize 时手动触发端侧重转，
      观察 `CoreMLInferenceGate` 是否串行化、是否消除 `EXC_BAD_ACCESS`。
- [ ] `CoreMLInferenceGateTests` 单测（模拟器已验证 maxConcurrent==1）。

### 7. LIVE VAD 门控 — 已从 LIVE 移除（弃用「丢帧」方案）

> 原「丢静音帧」门控已从 `RecordingSession` 移除（2026-07-26）。根因：流式 SpeechAnalyzer
> 依赖连续音频流，丢帧会饿死转写器（首 partial 需累积数百 ms 连续音频）→ **录音无字幕**
> （用户复现的 BUG；3s safety-net 兜底也救不回，单帧 ≈85ms 太稀疏吐不出字）；且其
> `result.range.seconds` 按「已喂采样」累计，丢帧压缩时间轴 → 会后说话人分离错位。
> `EnergyVAD` + 单测保留，待**结果层**重做（仅抑制 partial、永不抑制 final）后再验。

- [ ] （待重构后）静音段是否不再产生幻听废话 partial。
- [ ] （待重构后）final 永远显示——VAD 误判时最坏只是「不够实时」而非「无字幕」。

### 8. 电池
- [ ] 30 分钟 LIVE（VAD 开）耗电 % vs VAD 关。
- [ ] 60 分钟会议（LIVE + 会后重转）总耗电 %。

## 已知待补（不阻断 POC，记录后续）
- **scenePhase 后台护栏**：`MeetingSession.cancelPostMeetingCompute()` 已备，但未接入 View 的
  `onChange(of: scenePhase)`。iOS 27 #738 后台 ANE 锁定对「会后任务进行中切后台」的边角场景，
  目前靠「会后任务在 REVIEW 前台态完成」规避；POC 若复现再补。
- **热词接 FluidAudio**：FluidAudio 中文无热词接口，人名/术语纠错靠后处理（本期未做）。
- **VAD 自适应阈值**：当前固定 -38 / -45 dBFS，远场/不同机型可能需自适应。

## 通过标准
1–6 项全绿（尤其 **CER 明显优于 SpeechAnalyzer**、**#661 不崩**、**长音频丢字可接受**）
→ 设置里打开 `fluidRetranscribeEnabled`（`vadGateEnabled` 低风险，可更早开）。
任一项红 → 保留 flag 关，回 `RecapASRBench` 调参或等 FluidAudio 版本修复。
