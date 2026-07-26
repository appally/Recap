# RecapApp

投产 iOS 应用工程。从 `RecapASRBench`（功能验证）与 `RecapPrototype`（前端 DEMO）组装而来。

当前版本：**0.8.0**（Fun-ASR 主云端 + SpeechAnalyzer 资源安装）

## 模块

| Target | 职责 | 依赖 |
|---|---|---|
| RecapModels | SwiftData @Model + 值类型 + Keychain | — |
| RecapASR | SpeechAnalyzer + FunASR + VolcASR（备）+ RecordingSession | Models |
| RecapLLM | OpenAI 兼容 client + MinutesPipeline | Models, OpenAI SPM |
| RecapPersistence | ModelContainer + 种子数据 | Models |
| RecapUI | DesignSystem + 列表/纪要/设置 | Models, ASR, LLM, Persistence |
| RecapApp | 入口 | Persistence, UI |

## 生成工程

```bash
cd /Users/liuyong/Projects/Recap/RecapApp
xcodegen generate
open RecapApp.xcodeproj
```

纯 SPM，无 CocoaPods。修改 `project.yml` 或增删源文件后重新 `xcodegen generate`。

## 构建

```bash
# 模拟器
xcodebuild -project RecapApp.xcodeproj -scheme RecapApp \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# 真机
xcodebuild -project RecapApp.xcodeproj -scheme RecapApp \
  -destination 'generic/platform=iOS' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## 测试

```bash
cd /Users/liuyong/Projects/Recap/RecapApp
xcodegen generate

# 按本机模拟器调整 name；也可用 id=
xcodebuild test -project RecapApp.xcodeproj -scheme RecapApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RecapModelsTests -only-testing:RecapLLMTests \
  CODE_SIGNING_ALLOWED=NO
```

## 首次使用

1. 打开 App → 右上角设置
2. 粘贴 DeepSeek API Key（纪要 / 待办 / 问 Recap）
3. 粘贴阿里百炼 API Key（Fun-ASR 云端转写；推荐）
4. （可选）火山 App ID + Access Token 作备路
5. 引擎偏好默认「自动」：SpeechAnalyzer → Fun-ASR → 火山 → 演示字幕
6. 点底部录音按钮开始会议  
   - 首次端侧转写会下载 zh-CN 语音资源，稍等即可

详细勾选见 [`真机验收清单.md`](真机验收清单.md)。

## 文档

- 迁移计划：[`../RecapApp迁移计划.md`](../RecapApp迁移计划.md)
- 产品方案：[`../产品设计方案.md`](../产品设计方案.md)
