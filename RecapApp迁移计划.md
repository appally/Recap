# RecapApp 迁移计划

> 版本：v1.1 ｜ 日期：2026-07-25
> 决策：另起新工程组装两边资产，不改造 RecapASRBench / RecapPrototype
> 状态：**P0–P6 全部完成**（投产工程基座就绪）

---

## 一、决策结论

| 决策 | 选定 | 影响 |
|---|---|---|
| 云端 ASR | VolcASREngine（WebSocket 直连） | 去 CocoaPods、去 SpeechEngineToB SDK、模拟器可跑、纯 SPM |
| 模块化 | XcodeGen 多 target | internal 跨 target 不可见；sources 指文件夹免手改 pbxproj |
| Model 统一 | @Model 直驱 UI | SwiftData `@Query` 驱动 View |
| 工程位置 | `RecapApp @ /Users/liuyong/Projects/Recap/RecapApp/` | bundleId `com.recap.app` |
| 端侧 ASR | SpeechAnalyzer 单引擎 | 不引入 FluidAudio |

---

## 二、工程骨架（已落地）

```
RecapApp/
├── project.yml                 # 6 target + OpenAI SPM
├── App/                        # 入口
├── Modules/
│   ├── RecapModels/            # @Model + Keychain + 值类型
│   ├── RecapASR/               # 协议 / 双引擎 / AudioRecorder / RecordingSession
│   ├── RecapLLM/               # Provider / MinutesPipeline / Smoke
│   ├── RecapPersistence/       # ModelContainer + 种子数据
│   └── RecapUI/                # DesignSystem + 列表/纪要/设置
├── README.md
└── 真机验收清单.md
```

依赖：`UI → Models + ASR + LLM + Persistence`；`ASR/LLM/Persistence → Models`；`App → Persistence + UI`

---

## 三、分阶段执行（结果）

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P0 脚手架** | 目录 + project.yml + xcodegen + 空壳可运行 | ✅ |
| **P1 Models+Persistence** | @Model + Speaker + RecapDataContainer | ✅ |
| **P2 ASR+Audio** | 流式协议 + 双引擎 + Keychain 凭证 | ✅ |
| **P3 LLM** | MinutesPipeline + 冒烟 | ✅ |
| **P4 UI 迁移** | Prototype UI → @Model/@Query | ✅ |
| **P5 端到端接线** | RecordingSession + SettingsView | ✅ |
| **P6 验证清理** | Demo 降级收口 + 验收清单 + 编译回归 | ✅ |

---

## 四、运行时降级策略

| 能力 | 优先 | 回退 |
|---|---|---|
| LIVE 转写 | SpeechAnalyzer → 火山 | `DemoContent` 演示字幕 |
| 纪要/待办 | DeepSeek MinutesPipeline | `DemoContent.fallbackSummary` + 演示待办 |
| 问 Recap / 技能 | DeepSeek 流式 | 本地演示文案 |

---

## 五、后续（基座之外，非本迁移范围）

- App Icon 实图、签名与 TestFlight
- EventKit 待办分发（产品方案行动层）
- 说话人分离 / diarization 接入
- Skill 系统 SKILL.md 与 HITL 深化
- 去掉首次启动种子数据（或改为「示例」标记可删）

真机步骤见 [`RecapApp/真机验收清单.md`](RecapApp/真机验收清单.md)。
