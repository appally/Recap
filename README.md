# Recap — 开放的本地会议记忆

**Your models. Your data. Your memory.**

Recap is an open-source (AGPL-3.0), local-first meeting memory app for iPhone/iPad (iOS 26+): on-device live transcription, voiceprint-based speaker identity that persists across meetings, commitment/action tracking with evidence quotes and reminders, and a tool-calling agent over your own history. Bring your own LLM (any OpenAI-compatible endpoint) and your own ASR — nothing is locked to any model vendor, and your data never has to leave your device. 中文文档为主，English summary above.

> 见过的每个人，答应过的每件事，都替你记着——用你自己选的模型，存在你自己的设备上。

## 它能做什么

- **端侧实时转写**：SpeechAnalyzer 现场字幕（LIVE 检查点防丢）；会后重转可选端侧 SenseVoice（多语种）或云端引擎。
- **谁是谁**：声纹身份层——说话人跨会议归名（「上次和王总聊到哪了」），命名一次，从此跟人走；误并可纠正回流。
- **说过的算数**：承诺/待办自动抽取，带原文证据与时间戳回跳，经确认后进提醒（EventKit 闭环），到点有人催。
- **听得懂现场**：录音落盘可回听；转写句三色高亮（LIVE/回听/手写 Moment）；外部音频可导入转纪要。
- **问 Recap**：多步 Agent 内核（11 个工具：跨会议检索、读网页、改纪要、建提醒…），会话与轨迹可恢复可审计，写操作需人工确认（HITL）。
- **自定义一切**：任意 OpenAI 兼容大模型端点（DeepSeek / 通义 / GLM / Kimi / 豆包 / OpenAI / Claude / Gemini / 本地 Ollama…，058 起对所有用户免费）；技能是标准 SKILL.md 文档，可自建可分享；自定义转写引擎（规划中，见 Roadmap）。
- **数据是你的**：全部数据本机 SwiftData；逐字稿/纪要/SRT/PDF/长图随时免费导出；开放工作区格式（规划中，见 `docs/schema.md`）。

## 自建（Self-build，免费路径）

要求：macOS + Xcode 26（iOS 26 SDK）。**不需要任何账号**——端侧转写 + 自备密钥即为完整功能。

```bash
brew install xcodegen
git clone <this-repo> && cd Recap
cd RecapApp && xcodegen generate
cd .. && sh scripts/fix_scheme.sh   # 修正 scheme 产物名（必须在仓库根执行）

# 构建注意：必须用「具体模拟器」（arm64-only）——
# generic destination 会连带编 x86_64 切片，而 FluidAudio 的
# NemoTextProcessing.xcframework 不含该切片（链接失败）。
UDID=$(xcrun simctl list devices available | grep "iPhone" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')
cd RecapApp
xcodebuild -project RecapApp.xcodeproj -scheme RecapApp \
  -destination id=$UDID -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

本地测试托管档（可选）：scheme 挂 `RecapApp/Recap.storekit`。云端网关在 `cloud/`（Cloudflare Workers），`npm install && npx wrangler dev` 可本地起。

## 架构

```
RecapApp/
├── Modules/
│   ├── RecapModels/      领域模型 + 凭证/偏好（无 UI）
│   ├── RecapASR/         转写引擎协议 + SpeechAnalyzer/Fun/SenseVoice + 分离/声纹
│   ├── RecapLLM/         OpenAI 兼容 Provider + Agent 内核（Kernel/Tools/Skills）
│   ├── RecapPersistence/ SwiftData 容器
│   └── RecapUI/          界面（LIVE 舞台 / 纪要 / 设置 / 账户）
├── Controls/             控制中心控件 + Live Activity（WidgetKit extension）
└── Tests/                ~390 单测（Models / LLM / ASR / UI）
cloud/                    凭证签发网关（CF Workers + TS，vitest）
plans/                    55+ 编号实施计划（含波次与验收门槛，执行史即文档）
```

原则：**配置即数据，引擎即插件，技能即文档，数据即文件**。安全模型见 [`docs/security-model.md`](docs/security-model.md)。

## 常见问题

- **去哪拿大模型 Key？** 各厂商控制台（DeepSeek/OpenAI 等）或本地跑 Ollama/LM Studio；设置 → 大模型 → 自备密钥，填入即可，一分钟出纪要。
- **我的模型/端点不支持某些能力？** 常见差异（thinking、tool calling）有降级路径；仍失败请带「供应商 + 模型 + 报错」提 issue，社区维护验证组合清单。
- **本地模式与官方云端的区别？** 本地/BYOK：数据不出你配置的范围，永不限量。官方云端（可选）：免配置的便利托管，Pro 订阅代付，有月度额度。两者随时可切。

## 合规提醒

会议录音须遵守当地法律并告知与会者；部分场景需事先取得同意。App 内置「账户删除」（App Store 5.1.1(v)），云端仅存配额计数，不存用户内容。

## 参与

见 [CONTRIBUTING.md](CONTRIBUTING.md)——代码之外，**技能模板与供应商配方就是数据文件**，是最轻量的贡献入口。路线见 [ROADMAP.md](ROADMAP.md)。

## License

[AGPL-3.0](LICENSE)。版权人保留以其它 license 再许可的权利（含 App Store 分发）。三方组件见 [NOTICE.md](NOTICE.md)。
