# Plan 061: 自定义 ASR——OpenAI 兼容转写引擎（会后/导入路径，POC-gated）

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

## Status

- **Priority**: P1（《开放化战略》P1「引擎即插件」：ASR 是开放度差距最大的一层；POC-gated，模式同 039/055——**Release 默认关**，真机数据过门槛才转正）
- **Effort**: M（新引擎 + 配置存储 + 设置 UI + 解析器单测）
- **Risk**: MEDIUM（multipart 上传/长音频内存、segments 映射正确性；LIVE 不可用需产品语义清晰）
- **Depends on**: **058 硬**（ASR 设置门禁先废除）
- **Category**: feature / openness

## Why this matters

现状 ASR 引擎是编译期枚举（SpeechAnalyzer/Fun/Fluid），用户能填的只有百炼 Key——「不用锁死在任何模型公司」在转写层完全不成立。而转写质量恰是这个品类的根，且供应商光谱最宽：OpenAI/Groq/SiliconFlow 的 whisper 系、百炼 compatible-mode 的 paraformer/sensevoice 批式、本地 faster-whisper HTTP 服务，全都说 `/v1/audio/transcriptions` 这一种方言。v1 只覆盖**会后重转 + 外部导入**路径（HTTP 批式，协议收敛）；**LIVE 流式明确不支持**（WS 方言碎片化，列为社区/P2——设置页文案如实说明，不藏）。

## Current state（勘察结论）

- `AsrEngine` 协议（`Modules/RecapASR/AsrEngine.swift:19-61`）：批式 `transcribe(audioData:sampleRate:onPartial:)`（默认实现物化走流式，**可 override 走纯 HTTP**）+ 流式四件套 + `englishCapable`。协议默认实现给了天然落点：新引擎 override 批式、`startStreaming` 抛不支持。
- `AsrEngineKind`（`Modules/RecapModels/AsrEngineKind.swift`）：4 case 枚举；`AsrEngineFactory.make` switch（`AsrEngine.swift:148-155`）。
- 引擎选择：`ASRPreference`（auto/speechAnalyzer/funASR）+ `AsrEngineResolver`（LIVE 与重转共用 resolve 逻辑，**需勘察分流点**：LIVE 路径必须永不解析到 custom）。
- `ASRFeatureFlags`（UserDefaults，DEBUG/Release 默认不同）是 039/055 的 POC 门范式。
- 重转管线消费方：`MeetingSession` 重转/外部导入（plan 046/036 路径）按 preference resolve 引擎。

## Implementation

### Wave A: 数据与引擎

1. `Modules/RecapModels/AsrProviderStore.swift`：`CustomAsrProvider` Codable {id, name, baseURL, model（如 `whisper-large-v3`）, languageHint（可选）, apiKeyKeychainAccount(`asr.custom.<uuid>.apikey`)}；单 active（v1 单端点即够，多端点待真实需求）。UserDefaults key 版本化。
2. 新建 `Modules/RecapASR/CustomTranscriptionEngine.swift`（actor，实现 `AsrEngine`）：
   - `kind`：`AsrEngineKind` 新增 case `.customTranscription`（枚举加 case，检查其 RawRepresentable 持久化消费方兼容——勘察 `AsrEngineKind` 的 rawValue 落库点）。
   - `transcribe(audioData:)`：Float32 PCM → WAV 容器（本地无损封装，无转码）→ multipart `POST <baseURL>/audio/transcriptions`（`response_format=verbose_json`，带 model/language/api-key Bearer）→ 解析 `segments[]{start,end,text}` → `TranscriptSegment` 映射（时间戳秒→毫秒、说话人空、confidence nil）；`onPartial` 不支持（批式语义，忽略回调）。
   - `startStreaming` 抛 `AsrError.customStreamingUnsupported`（新增 case，文案「自定义转写引擎仅支持会后重转/导入」）。
   - `prepare()`：校验配置齐备（URL/Key/模型名），不发网络请求（连接测试另有入口）。
   - `englishCapable`：`languageHint == nil` 时 true（whisper 系自动检测），指定语言按语言判断。
3. `AsrEngineFactory.make` 增 case 分支；**分片上传是必做不是后备（诊断 F5）**：主流供应商对 `/audio/transcriptions` 硬限 25MB（OpenAI/Groq 免费档），16kHz 16-bit mono ≈ 1.92MB/min → 25MB 仅 ≈13min——整段上传在 Wave C 的 60min 门槛上必然失败。设计：PCM 物化时按 10min 固定窗切 **Int16** WAV（Float32→Int16 降宽减半体积），`URLSession.uploadTask(fromFile:)` 文件直传（不在内存拼 body——60min Float32 ≈230MB 常驻是 047 时代已知坑，诊断 F7）；新增 `ChunkedTranscriptionStitcher`（时间戳偏移 + 0.5s 重叠去重 + 相邻段 gap<0.3s 合并），单测覆盖边界切句。静音切点（能量 VAD）保留为 POC 误差不达标时的升级路径。

### Wave B: 解析与门控

1. `ASRPreference` 增 `.custom`（UserDefaults rawValue 兼容检查）；`AsrEngineResolver`：**LIVE 路径遇 `.custom` 回落 `.auto` 语义并记日志**；重转/导入路径正常解析。
2. `ASRFeatureFlags.customTranscription`：**Release 默认 false**（设置页入口整个隐藏，非灰置）；DEBUG 默认 true。
3. 设置页（`ASRSettingsView`）：flag 开启时出现「自定义转写引擎」分区——端点/模型/Key 表单 + 连接测试按钮（上传 3 秒静音 WAV，报告可达性/延迟/模型名有效性）；**启用前置 = 连接测试通过**（guided，诊断 F14）；分区头部内联两行明示：「仅会后重转/外部导入，不含 LIVE 实时转写」+「音频将发送至 <host>」。
4. 单测（RecapASRTests）：verbose_json 解析（标准/缺 confidence/空 segments/错误 JSON）、WAV 封装头正确性、`startStreaming` 抛错语义、resolver 的 LIVE 回落。

### Wave C: POC（真机，用户参与）

门槛（同 039 纪律，全过才翻 Release 默认）：
1. **正确性**：3–5 段真实中文会议（含 1 段英文），custom（whisper-large-v3 或百炼 sensevoice 批式）vs SpeechAnalyzer 重转，CER/可读性不劣于 SA；
2. **工程**：60min 会议重转成功（分片路径；内存峰值 < 500MB、拼接时间戳误差 < 300ms、无超时失败）；
3. **成本可见**：设置页显示「按供应商计费，与 Recap 无关」。

## Verification

1. 构建 + RecapASRTests 新增测试绿 + 既有 `FunASRLanguageTests`/merger 测试回归。
2. DEBUG 构建 + flag 开：配置端点（建议百炼 compatible-mode `sensevoice-v1` 或 Groq `whisper-large-v3`，用户已有 Key）→ 导入一段外部音频 → 引擎选 custom → 重转出带时间戳转写。
3. LIVE 开录：引擎偏好为 custom 时自动走 `.auto`（SA），字幕正常。
4. Release 构建：设置页无该入口（flag 关），无行为变化。

## STOP conditions

- `AsrEngineKind` 加 case 引发持久化/decoder 破坏性改动超出「向后兼容默认值」范畴——停下贴消费方清单。
- 分片+拼接在真机 POC 中时间戳误差可感（说话人重叠段错位）——记录数据，Wave C 记 PARTIAL，评估静音切点（能量 VAD）替代固定窗口后再议；仍不过则降级「≤30min 可用 + 设置页明示」。百炼批式文件上限未核实（POC 第一步先验证），若其上限显著小于 25MB，把它从推荐端点降级为社区配方。
- POC 正确性门槛不过（CER 显著劣于 SA）——**保留代码、flag 默认关、状态记 REJECTED（数据留档）**，不转正。


## 执行记录（2026-09-30）

- **Wave A+B DONE（代码）**：`AsrProviderStore`（单端点 v1，覆盖保存清理旧 Key account）；`CustomTranscriptionEngine`（actor，10min 分片 + Int16 WAV ≈18.5MB/片 + `upload(fromFile)` 直传 + verbose_json 解析；流式诚实抛不支持）；`ChunkedTranscriptionStitcher`（时间轴偏移 + 重叠双规则去重 + 边界碎句合并）；接线 `AsrEngineKind/.customTranscription` + 工厂 + `ASRPreference.custom`（flag 关时选择器隐藏）+ resolver `allowCustom` 参数（**LIVE（RecordingSession:99）恒 false**，.custom 偏好 LIVE 回落 auto）；`ASRFeatureFlags.customTranscription` DEBUG 开/Release 关；设置区 `CustomAsrSection`（3 秒静音 WAV 连接测试，保存前置=测试通过，范围+外发明示）。
- **验证**：BUILD SUCCEEDED；CustomTranscriptionTests 8/8（WAV 头逐字段/25MB 换算/verbose_json/拼接三规则/存储 round-trip；1 例 Keychain 断言本机环境跳过，CI 全量）+ 全量回归绿。
- **Wave C（真机 POC）待用户**：门槛不变（CER 不劣于 SA / 60min 分片内存 <500MB / 拼接误差 <300ms）；未过线 Release 默认保持关。百炼批式文件上限未核实仍是 POC 第一步。
- **状态：IN PROGRESS（代码完成，POC 数据待真机）**。