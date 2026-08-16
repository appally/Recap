# 052 · 端侧模型四件套诊断与优化改造方案

> 2026-08-16 · 覆盖：说话人模型（SpeakerKit）/ FluidAudio 分离引擎（FluidDiarizer）/ 会后端侧高保真重转（SenseVoice）/ 端侧模型下载生命周期。
> 方法：四路并行代码勘察 + 关键结论人工复核（含 3 处亲验）+ RecapASRTests 全绿验证（2026-08-16 模拟器，EXIT=0）+ Bench 工程产物清点。

---

## 0. 一页结论（TL;DR）

| 资产 | 大小 | Release 生产可达性 | 存在必要性判定 | 核心问题 |
|---|---|---|---|---|
| SpeakerKit 说话人分离（4×pyannote CoreML） | 11MB **bundle 预置** | ✅ 默认引擎，零下载 | **必要，保留**（生产唯一分离引擎） | 质量零量化；voiceprintId 恒 nil 连累身份功能 |
| FluidDiarizer（pyannote+WeSpeaker） | 几十MB 运行期下载 | ❌ **不可达**（flag 默认关 + UI `#if DEBUG`） | **战略必要，建议转正**（声纹身份层唯一地基，不可替代） | 「编译进包但用户摸不到」的最差状态；量化对比零产物 |
| SenseVoice 端侧重转（fp16） | 447MB 运行期下载 | ❌ **不可达且不可下载** | **商业必要，建议转正**（Free/BYOK 高保真路径 + 离线兜底） | 同上；且自动路径缺拒收守卫、文案错位 |
| Apple SpeechAnalyzer 资产 | 系统托管 | ✅ 免费档 LIVE 主路径 | 必要 | 真机中文质量零量化（顺带发现，不在本方案范围） |

**三句话诊断**：
1. **最大问题不是质量，是「没有发布决策」**——FluidDiarizer 与 SenseVoice 以实验 flag + DEBUG-only UI 的形态编译进 Release 包：付出全部二进制体积、维护与合规成本（第三方许可声明都在），用户收益为零。这不是保守发布，是薛定谔状态。
2. **已建成的产品功能在等一个不存在的引擎**——人物视图（051）、发言复盘「记住我」、「这是我」跨会议识别、纠错终身生效，全部依赖 voiceprintId；而生产唯一引擎 SpeakerKit 永远给不出 voiceprintId。功能与引擎脱节。
3. **生产有一个真实 UX bug**：REVIEW 态每行说话人名是无条件可点的按钮，SpeakerKit 路径下点了**毫无反馈**（`handleMarkMe` 对 nil voiceprintId 静默 return）。

---

## 1. 现状全景（已验证事实）

### 1.1 四块资产的链路与 Release 可达性

```
LIVE 录音（零分离，全部挂占位说话人 "asr-live"/「转写」）
   │  引擎：SpeechAnalyzer（免费档/BYOK 端侧）或 Fun-ASR 云端（Pro / 国行非AI机型）
   ▼
endLive 收尾（MeetingSession.swift:1448-1463）
   ├─ ① maybeDialectRetranscribe   方言置信度<0.4 → 云端 Fun-ASR 重转（仅 .speechAnalyzer 路径）
   ├─ ② maybeOnDeviceUpgrade       ①未成功 → SenseVoice 端侧重转
   │     闸门：fluidRetranscribeEnabled(Release默认关) && modelsPreloaded && .speechAnalyzer
   ▼
startProcessing（LLM 纪要管线，吃重转后的稿）
   ▼
REVIEW 态 scheduleDiarizationIfNeeded（MeetingSession.swift:1710）
   └─ DiarizationService.activeDiarizer = fluidDiarizerEnabled ? FluidDiarizer : SpeakerKit
        SpeakerKit：bundle 预置 11MB ✅ ｜ FluidDiarizer：需下载几十MB，Release 开关不存在
```

### 1.2 开关与闸门矩阵（亲验 `FeatureFlags.swift`、`ASRSettingsView.swift:47-51`）

| 开关 | 键 | 默认 | UI 入口 | Release 实效 |
|---|---|---|---|---|
| 分离引擎切换 | `asr.fluidDiarizerEnabled` | false（不分构建） | `#if DEBUG` | **不可开**（除非手写 UserDefaults） |
| 端侧重转 | `asr.fluidRetranscribeEnabled` | DEBUG=true / Release=false | `#if DEBUG` | **不可开** |
| 预下载闸门 | `asr.fluidModelsPreloaded` | false | —（由下载成功置位） | 永不置位（Release 无下载入口） |
| 方言阈值 | `asr.dialectConfidenceThreshold` | 0.4（预估，未标定） | 无 UI | 生效中 |
| 声纹同意 | `recap.voiceprint.consentGranted` | false | 独立同意页 | 生效但无消费方（画廊只在 FluidDiarizer 路径读写） |

推论：**Release 用户实际发生的模型下载只有 Apple SpeechAnalyzer 系统资产一种**。SpeakerKit 走 bundle；SenseVoice/FluidDiarizer 三重闸死。设置页「转写与说话人」在 Release 只剩引擎状态卡 + 声纹说明（无录入入口）。

### 1.3 质量证据清单（有什么 / 缺什么）

| 项 | 已有证据 | 缺口 |
|---|---|---|
| SenseVoice 中文准确率 | AISHELL-1 CER 3.09%（**Mac M5**，选型文档）；记忆称长音频 7.81%（**产物未留存，需重测**） | iPhone 真机 CER（fp16 vs int8）、RTFx、内存峰值（文档口径 0.54GB fp16）、发热 |
| SpeakerKit 分离质量 | 无 | DER、说话人数准确率、段边界精度（真机） |
| FluidDiarizer 分离质量 | D47 真机跑通、无 #661 崩溃（2026-07-29） | 同上 + 与 SpeakerKit 的对照（**BenchRunner 已支持 diarize 跑分但从未产出结果，且无 DER 度量只有 speakerCount/段数**） |
| 方言检测阈值 0.4 | DialectDetectorTests 8 用例（逻辑级） | 真实方言/普通话混合语料标定 |
| Apple SpeechAnalyzer zh | 无 | 真机 CER（免费档主路径！） |

测试现状：RecapASRTests 2026-08-16 全绿，但全部是契约/对齐/mock 级；下载、闸门置位/清零、模型完整性、重转覆盖语义**零单测**（`maybeOnDeviceUpgrade`/`shouldRejectRetranscribe` 均 private）。

---

## 2. 逐项诊断

### A. SpeakerKit 说话人模型 —— 定位正确，实现干净，短板是「无身份、无量化」

- **定位**：生产默认会后分离引擎。LIVE 零分离 → REVIEW 批处理 → SpeakerAligner 按时间重叠对齐到转写行。超时预算 `时长×3+300s`，热节流，150s idle 卸载，内存告警卸载——生命周期设计完善。
- **bundle 预置是最优解**（已亲验 `project.yml:171-176` folder reference + `SpeakerKitDiarizer.swift:31` 命中即跳过预取）：冷启动零网络零损坏。hf-mirror 下载链 + 4×mlmodelc 结构完整性校验 + 坏缓存 purge 重下，只作为 bundle 缺失的兜底，留着无害。
- **问题 A1（生产 UX bug，P0）**：`MeetingNoteView.swift:2557` 无条件给每行传 `onMarkMe`，`handleMarkMe`（:2500）对 nil voiceprintId 静默 return——SpeakerKit 路径（= 全部 Release 用户）点说话人名无任何反馈。
- **问题 A2**：设置页「提前下载说话人模型」卡（DEBUG-only）对 bundle 已预置的现实是死 UI——bundle 命中时 `prepare()` 秒回「已就绪」，卡片无意义。
- **问题 A3**：分离质量从未量化。用户拿到的说话人标注好不好，没有任何数据支撑迭代。

### B. FluidDiarizer —— 不是「另一个分离引擎」，是身份层地基；但生产不可达

- **独有能力**（SpeakerKit 架构上给不了）：WeSpeaker 256 维 embedding → 引擎稳定 String id 作 voiceprintId → 跨会议名字重放（047 双层 key）、声纹画廊演化（EMA 0.9 + rawEmbeddings≤50）、「这是我/标记我」、人物视图「与 TA 的会议」（051）、纠错终身生效（rename 不置 isPermanent / merge 吸收 embedding）。
- **合规设计正确**：PIPL §28 敏感个人信息独立同意门（`VoiceprintConsentSheet`，非捆绑），同意只挡画廊读写不挡分离——未同意时本场身份仍有效、不收集 embedding。声纹仅本机、`Application Support/VoiceprintGallery.json` 每人 ~1KB。
- **工程护栏完善**：CoreMLInferenceGate 全局串行（#661）、ManagerBox 隔离、isInferring 50ms 轮询保护卸载、ENOMEM 1.5s 重试、内存/热/后台三路卸载。
- **问题 B1（核心）**：flag 默认关 + 开关 UI `#if DEBUG` → Release 不可达。而 051 人物视图、发言复盘「记住我」已随包发布——这些功能在生产全部空转。**功能先于引擎上线了**。
- **问题 B2**：量化对比零产物。BenchRunner 已具备 diarize 评测能力（speakerCount/segmentCount），但没有 DER 度量、没有跑过、结果不归档——「真机 POC 通过后再考虑默认开」的 POC 其实只完成了一半（跑通≠达标）。
- **问题 B3（次要）**：`DiarizerConfig` 是包内 internal，`numberOfSpeakers` 入参是死参数，聚类/阈值（cosine 0.84/0.56、minSpeechDuration 1s、chunk 10s 零重叠）不可调——调参需 fork 上游或等开放。chunk 边界 <1s 段被丢弃、边界切换靠 EMA 而非声学拼接，中文会议快节奏抢话场景未验证。
- **问题 B4（边界）**：DEBUG 真机开过 flag 后，UserDefaults 键在装 Release 壳时依然生效（启动还会预取几十MB）——可接受，但转正设计时要知晓。

### C. SenseVoice 会后端侧高保真重转 —— 定位清晰（fork B：Free/BYOK 升级、Pro 保云端），但生产不可达 + 两处实缺陷

- **链路健康面**：mmap + AudioSilenceChunker 按段物化（26s 段 ~1.7MB）内存克制；三重闸门防 447MB 被动下载设计正确；失败静默保留原稿；方言云端重转优先、端侧兜底的次序合理（方言命中但云端 403/失败时端侧仍跑，实际是二道兜底——注释说「互斥」与行为有出入，但行为是对的）。
- **问题 C1（实缺陷，P0）**：`maybeOnDeviceUpgrade`（`MeetingSession.swift:1198`）**非空即整表覆盖**——没有 `shouldRejectRetranscribe` 守卫（方言/手动路径有：旧稿≥200 字且新稿 <60% 拒收）。SenseVoice 大面积丢字时会毁掉更完整的 LIVE 稿再进纪要管线。一行级修复。
- **问题 C2（实缺陷，P0）**：`.retranscribing` 舞台标题硬编码「检测到方言口音，云端精转中…」（`MeetingSession.swift:44`）——端侧路径也显示这句；且「端侧高保真重转中…」statusMessage 在 processing 态不渲染。用户看到的与实际发生的对不上。
- **问题 C3**：Release 不可达且不可下载（flag 默认关 + 预下载卡 `#if DEBUG` + 自动闸门要 preloaded + `resolveCloudFirst` 兜底同样要 preloaded）。FeatureFlags.swift:13 注释「手动重转菜单用户点选才下载」与现实不符——菜单路径也有闸门，**Release 下 447MB 模型永远下不来**，防被动下载的闸门实际变成了功能不存在。
- **问题 C4**：手动「重新转写」只有 cloudFirst（Fun-ASR → SpeechAnalyzer → SenseVoice 兜底），用户无法指名端侧重转；`retranscribeFromDisk(engineKind:)`（`MeetingSession.swift:860`）成了无调用方的死代码。
- **问题 C5**：447MB fp16 的选择依据是「int8 部分机型 ANE 编译失败回退 CPU 会 NaN」（`FluidAudioEngine.swift:28-30`）——「部分机型」的机型面从未测定。int8 是 225MB（**体积减半、AISHELL CER 无损**），若真机验证通过，下载门槛、磁盘占用、内存峰值（0.54→0.32GB）三项全降。

### D. 下载生命周期 —— 骨架好，缺「对账」与「出口」

- **做得对的**：全部流量走 hf-mirror（tree API + resolve，符合镜像约束）；FluidAudio 断点续传（.partial + Range + If-Range + 416 自愈）与 ArgmaxCore（.incomplete + Range）都有；模型放 Documents/App Support 不会被系统清；iCloud 备份排除幂等覆盖；磁盘预检分级（50/100/500MB）；下载与推理分离（下载不进 CoreML gate）。
- **问题 D1**：**无任何模型清理/回收入口**——447MB 一旦下载只能卸载 App 回收；`ModelHub.clearAllCaches()` 包里有但 App 未接。iOS 存储 设置里用户只看到 App 总体积。
- **问题 D2**：`modelsPreloaded`（闸门）/`fluidModelsReady`（卡片态）双轨 UserDefaults，与磁盘实况无对账——手动删文件后 flag 仍真，直到某次 prepare 失败才清零。
- **问题 D3**：无 sha256 内容校验（尺寸 + HTML 嗅探 + 加载失败 purge 兜底）。hf-mirror 是第三方镜像，供应链面上值得把已知哈希写死校验，至少对 447MB 大件。
- **问题 D4**：无 BGAppRefreshTask/BGTaskScheduler 夜间下载路径——转正后「WiFi+充电时预取」没有载体。

---

## 3. 存在必要性与定位建议（拍板论证）

> **拍板记录（2026-08-16）**：用户同意 **双转正**（FluidDiarizer + SenseVoice 均走 §3.2/§3.3 的 opt-in 转正路径）。P0 四项已先行落地（见 §4 P0 表状态）。下一步入口为 P1-2（Bench 量化）与 P1-4（Release opt-in 入口）。

### 3.1 SpeakerKit：保留，定位不变
生产默认分离引擎，11MB bundle、零下载、生命周期完善。**没有任何理由动它**——它的短板（无跨录音身份）不是它的错，是定位如此。

### 3.2 FluidDiarizer：建议**转正**，理由是「不可替代性」而非「分离质量」
- 声纹身份是「纪要」的差异化叙事（跨会议认人、人物视图、纠错终身生效），且**产品侧已经建完了**（047/050/051）。砍掉 FluidDiarizer = 承认人物功能永久空转；转正 = 已沉没的产品投入直接变现。
- 转正不等于默认开。两阶段：
  - **Phase 1（本方案 P1）**：开关出 `#if DEBUG`，Release 可 opt-in（带「实验」标注 + 体积/编译耗时披露）；量化补齐。
  - **Phase 2（数据说话）**：DER 对比不劣于 SpeakerKit 显著幅度 → 默认开（或默认开且保留回退开关）；劣于 → 冻结在 opt-in，人物功能标注「需开启实验开关」。
- 若最终选择不转正：则应反向砍依赖（人物视图轨迹、记住我、画廊 UI 降级或移除），否则功能债继续滚动。**中间状态不可持续**。

### 3.3 SenseVoice：建议**转正为显式 opt-in 的「本机精转」能力**，不建议默认开
- 商业逻辑：免费档云端 ASR/LLM 是服务器成本，端侧是边际零成本——SenseVoice 是免费额度耗尽/离线/隐私敏感场景的兜底与升级路径；Pro 用户无感（fork B 已正确隔离）。
- 447MB 是用户设备上的重决策：**永远不该静默下载**（现行闸门方向正确），但必须有正式的 opt-in 入口与价值话术（「下载 447MB，本机精转免费不限次」），而不是像现在一样连入口都没有。
- int8 路线值得一次真机验证（C5）：通过则门槛减半，转正阻力大降。

### 3.4 下载时机策略（若按上述转正）

| 模型 | 时机 | 条件 | 形态 |
|---|---|---|---|
| SpeakerKit | 不下载（bundle） | — | 维持现状；DEBUG 预下载卡删除或改为诊断工具 |
| FluidDiarizer | flag 开启后的下一次启动（已有 Warmup 预取）+ 首次用到懒加载兜底 | 建议加 WiFi 闸；几十MB 可静默 | 后台预取 + ANE 特化编译错峰（已有 2s delay / 开麦让路） |
| SenseVoice | ① 设置页常驻下载卡（Release 化）② 价值时刻引导：免费用户首次会议结束 / 云端额度提示页的「离线替代」入口 | **显式点按 + WiFi + 充电 + 磁盘 ≥500MB（已有）+ 体积明示** | 下载进度 + 可取消 + 完成后可清理 |
| 方言云端重转 | 不变（endLive 自动） | — | 已投产 |

夜间预取（BGTaskScheduler）不作为首期：opt-in 模型用户主动下载即可，工程面（D4）留 P2。

---

## 4. 改造清单

### P0 —— 生产缺陷，立即修（不依赖拍板）

> **状态（2026-08-16）：四项全部落地**，全 scheme 测试绿。实施记录：
> - P0-1 采用「降级纯文本」而非提示 toast：Release 当前无 FluidDiarizer 开关入口（P1-4 才补），toast 指向不存在的设置项会误导；且长按「纠正发言人」已有解释文案。P1-4 落地后可重评估教育性入口。
> - P0-3 顺带删掉了端侧路径开头的 `statusMessage = "端侧高保真重转中…"`：该字段 processing 态不渲染、且 `commitAISummary` 进 REVIEW 不清空——成功后会以「重转中…」残留在转写页头部。
> - 回归测试 6 条进 `MeetingSessionLifecycleTests`（守卫 4 + 舞台文案 2），`shouldRejectRetranscribe` private→internal 供 @testable 测试。

| # | 问题 | 改法 | 验收 | 状态 |
|---|---|---|---|---|
| P0-1 | 「这是我」点击静默无效（A1） | SpeakerKit 路径（voiceprintId nil）下：`onMarkMe` 不传（名字降级为纯文本），或点击弹一句轻提示「当前分离引擎不支持跨会议识别，可在 设置→转写与说话人 开启」。倾向后者——入口教育价值 > 隐藏 | Release 模拟器点说话人名有反馈或不可点；FluidDiarizer 路径行为不变 | ✅ 采用降级纯文本（理由见上） |
| P0-2 | 端侧升级缺拒收守卫（C1） | `maybeOnDeviceUpgrade` 成功分支复用 `shouldRejectRetranscribe`（与方言路径同口径）；拒收走静默保留原稿 | 单测：旧稿 200 字 + 新稿 <60% → 不覆盖（需把守卫抽为可测纯函数） | ✅ 含 4 条单测 |
| P0-3 | 舞台文案错位（C2） | `.retranscribing` 标题按触发源区分：方言「检测到方言口音，云端精转中…」/ 端侧「本机精转中…」；「端侧高保真重转中…」statusMessage 在 processing 态可见或删除 | 两条路径各跑一遍，舞台文案与实际引擎一致 | ✅ 枚举带 cause 载荷；残留 statusMessage 一并删除 |
| P0-4 | FeatureFlags.swift:13 注释失实（C3 附带） | 改为如实描述三重闸门现状 | 评审通过 | ✅ |

### P1 —— 转正决策链（建议顺序执行，1-2 周）

> **状态（2026-08-16）**：代码侧可做的已全部落地（P1-4/P1-6 完成，P1-2 脚手架完成），剩余项全部卡真机。
> - **P1-4 ✅**：两张卡+分离开关移出 `#if DEBUG`（`ASRSettingsView.swift`），文案改用户价值口径（「跨会议声纹识别」替代「替代 SpeakerKit」等内部黑话），默认值不变（两 flag 仍默认关，显式 opt-in）。speakerModelSection 维持 DEBUG-only（P2-5 处理）。主 App 84 测试绿。
> - **P1-6 ✅**：覆盖拼图=另一会话的 3 条闸门诚实性测试（`FluidAudioEngineTests`，`preloadedGate` 纯函数）+ P0-2 的 4 条拒收守卫测试 + 既有 flag 默认值锁定（`FluidDiarizerTests.testFlagDefaultOff`）。
> - **P1-2 半✅**：`DERScorer`（RTTM 解析+边界切片+最优一对一映射，≤8 精确/贪心兜底）进 Bench `CERScorer.swift`，BenchRunner/ContentView/BenchRecord 全链接线，**13 条手算真值用例独立编译全过**（`plans/bench-results/der_scorer_selfcheck.swift` 可复跑）；评测战役规范落 `plans/bench-results/README.md`（测试集 S1–S5/标注规范/int8 A/B 流程/判定门槛）。**未完成**：真机跑分（需测试集音频+标注工时）。⚠️Bench 工程当前在本机无法编译——Pods 未安装（Volc `SpeechEngineToB`）+ `OpenAI` 模块未解析，属**既有损坏**与本批改动无关，跑分前需先 `pod install` 并补依赖。
> - **P1-3 / P1-5 待真机**：int8 A/B 与方言阈值标定流程已写进 bench-results README §三/§五。

| # | 事项 | 内容 | 验收 |
|---|---|---|---|
| P1-1 | **拍板：转正 or 剥离** | 本文档 §3.2/§3.3 提交决策。默认建议：双转正（opt-in 形态） | 决策记录回写本文档 |
| P1-2 | Bench 补 DER + 跑分归档 | BenchRunner 加 DER（需人工标注时间轴的测试集）+ CER（SenseVoice 真机 fp16 vs int8）；准备 3-5 段真实中文会议（1 人/2 人/多人/抢话/安静各一）；结果 JSON 归档进仓库 `plans/bench-results/` | SpeakerKit vs FluidDiarizer DER 对照表 + SenseVoice 真机 CER/RTFx/峰值内存表落盘 |
| P1-3 | int8 真机验证 | `preferInt8` 可开（UserDefaults 或 DEBUG 切换），覆盖现有测试机型面：验证 ANE 编译成功率、NaN、CER 差 | 通过 → 默认切 int8（225MB）；不通过 → 记录机型面，维持 fp16 |
| P1-4 | Release opt-in 入口 | 两张卡（分离模型/端侧模型）+ 分离引擎开关移出 `#if DEBUG`，文案加「实验」标注与体积/耗时披露；`fluidRetranscribeEnabled` Release 默认保持关 | Release 构建（TestFlight）可见可下载可重试；免费额度提示页/会后场景接线价值引导 |
| P1-5 | 方言阈值标定 | 用 P1-2 语料标定 0.4；产出误触发率（普通话被重转）与漏检率 | 阈值定稿（或维持 0.4 附数据） |
| P1-6 | 闸门单测 | `modelsPreloaded` 置位/清零、`shouldRejectRetranscribe`、两 flag 的默认值矩阵补进 RecapASRTests（守卫逻辑抽纯函数） | 全绿 |

### P2 —— 体验与工程收尾

> **状态（2026-08-16）**：P2-1/2/3/4/5/7 全部落地（同日第三批），主 App 84 测试绿。P2-6 维持不做（拍板：数据证明下载转化率是瓶颈才做）。顺手修正：diarizer 体积文案「约几十 MB」→「约 14 MB」（tree API 实测 13.7MB）。
> - **P2-1 ✅**：「本机模型」分区（有下载模型才出现）——占用字节数实测显示、单模型删除（确认对话框）、diarizer 删除前先 `unload()` 防删映射文件崩溃；删除同步清 `modelsPreloaded`/`fluidModelsReady`。
> - **P2-2 ✅**：设置页 onAppear 对账（磁盘实况回写 `fluidModelsReady`）+ diarizer 预下载卡补 ready 态；`modelsPreloaded` 的 getter 对账已由 2026-08-16 早前批次完成（`preloadedGate`）。
> - **P2-3 ✅**：12 项 LFS sha256 清单（SenseVoice 6 + diarizer 6，hf-mirror tree API 采集）烤进 `FluidAudioBootstrap.lfsSHA256`；两条下载链（preloadASRModels / FluidDiarizer.downloadAndWrap）下载后校验，失配即清除+抛错重试入口。清单 12/12 与源 JSON 程序化比对一致；哈希实现与 `shasum` 交叉验证一致。⚠️上游重传权重会失配——升级 FluidAudio 时须同步更新清单（代码注释已标）。
> - **P2-4 ✅**：删 `retranscribeFromDisk(engineKind:)` + `RetranscribeIntent.kind`（无调用方；cloudFirst 回落链已覆盖其全部真实场景，理由注释在位）。
> - **P2-5 ✅**：SpeakerKit DEBUG 预下载卡整段删除（bundle 预置使秒回就绪，死 UI）+ 状态变量清理。

| # | 事项 | 内容 |
|---|---|---|
| P2-1 | 模型清理入口 | 设置→存储：「本机模型」分区列出已下模型（名/大小/用途）+ 单删 + 全删；接 `ModelHub.clearAllCaches()`；删除时同步清 `modelsPreloaded`/`fluidModelsReady` |
| P2-2 | 闸门对账 | 启动或进设置时校验模型目录实况与 flag 对账（文件缺失 → 清 flag；卡显 ready 需实况支撑） |
| P2-3 | sha256 校验 | SenseVoice 447MB 大件写入已知哈希清单，下载后校验不符即弃（供应链加固） |
| P2-4 | 死代码处理 | `retranscribeFromDisk(engineKind:)`：要么接回 UI（「重新转写」菜单加「用本机模型重转」子项，供无网/额度尽场景），要么删除 |
| P2-5 | SpeakerKit DEBUG 预下载卡 | 删除或降级为「诊断」（bundle 已预置，卡片无意义） |
| P2-6 | BGTaskScheduler 夜间预取（可选） | 仅当 opt-in 转正后数据证明下载转化率是瓶颈才做 |
| P2-7 | 互斥注释对齐 | `endLive` 处「与方言重转互斥」注释改为「方言成功即跳过；失败时端侧兜底」如实描述 |

### 明确不动（并列出理由，防止反复）

- **SpeakerKit bundle 预置**：已是最优。
- **LIVE 零分离**：流式引擎（SpeechAnalyzer/Fun realtime）都不产 speaker，「LIVE 占位 + 会后批处理」是当前引擎格局下的正解；不引入流式 diarizer（无四边形战士，见端侧战略记忆）。
- **方言云端优先于端侧**：云端 paraformer 方言已验证（18 方言、¥0.864/h），保持。
- **CoreML gate / 生命周期护栏**：现有设计完善，不动。
- **Pro 不做端侧升级（fork B）**：商业分层正确。

---

## 5. 风险与依赖

- P1-2 的 DER 标注需要人工工时（3-5 段 × 每段 15-30min）；CER 参考文本可用现成转写人工校对产出。
- 转正（P1-4）动 Release 体验，建议排在上架审核空窗期实施，避免 4.3(a) 敏感期引入新审查面（新增「实验功能」入口需文案谨慎：不承诺准确率）。
- int8 切换（P1-3 若通过）影响已下载 fp16 用户——增量下载逻辑需处理精度切换（旧 fp16 目录清理）。
- FluidDiarizer 参数不可调（B3）在 Phase 2 若成瓶颈：fork 上游 open PR，或锁定 0.15.5 长期维护分支（当前 exact pin 策略兼容）。

---

## 附：勘察证据索引（关键引用）

- 开关/默认值：`FeatureFlags.swift:8-49`；Release UI 隔离：`ASRSettingsView.swift:47-51`（亲验）
- bundle 预置：`project.yml:171-176` + `App/speakerkit-coreml`（11MB 实测）+ `SpeakerKitDiarizer.swift:29-43,149-182`（亲验）
- 端侧升级链：`MeetingSession.swift:1156-1221`（触发/闸门/覆盖）、`:1448-1463`（endLive 次序）、`:956-963`（拒收守卫，端侧路径未用）
- 文案错位：`MeetingSession.swift:35,44`（亲验）
- markMe 死点：`MeetingNoteView.swift:2500,2557` + `Components.swift:144-157`（亲验）
- 下载/闸门：`FluidAudioEngine.swift:161-195`（mirror/preloaded/preload）、`AsrEngineResolver.swift:121-130`
- 生命周期：`MeetingSession.swift:1710-1776`（调度/卸载/后台取消）、`RecapAppApp.swift:93-112`（Warmup）
- 量化真空：`RecapASRBench/Benchmark/BenchRunner.swift`（支持 diarize 跑分，无 DER，无结果产物——find 全仓无 bench 结果文件）
- 测试：RecapASRTests 2026-08-16 全绿（本文档当日模拟器实跑）
