# NOTICE

本仓库分发的第三方组件与模型（license 已逐一核实于 SPM checkouts，2026-09-28）：

## Swift Package 依赖

| 组件 | 用途 | License |
|---|---|---|
| [MacPaw OpenAI](https://github.com/MacPaw/OpenAI) 0.5.1 | 结构化抽取路径的 OpenAI 兼容客户端 | MIT |
| [Argmax argmax-oss-swift（SpeakerKit）](https://github.com/argmaxinc/argmax-oss-swift) 1.0.0 | 说话人分离 + 声纹嵌入 | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.6 | 端侧 SenseVoice 转写（会后重转） | Apache-2.0 |
| swift-openapi-runtime / swift-http-types / swift-argument-parser（Apple） | OpenAPI 运行时 / HTTP 类型 / 参数解析 | Apache-2.0 |

## 二进制依赖（SPM binary target）

- `NemoTextProcessing.xcframework`（FluidInference text-processing-rs v0.3.0，FluidAudio 的文本正则化依赖）——随 FluidAudio 分发，Apache-2.0。**注意**：仅含 arm64 切片，构建须用具体（arm64）模拟器 destination，见 README 自建一节。

## 随包 CoreML 模型（license 已核实，2026-09-28）

- `RecapApp/App/speakerkit-coreml/`：来自 HF `argmaxinc/speakerkit-coreml`（pyannote v3/v4 的 CoreML 转换，经 `scripts/fetch_speakerkit_models.py` 预置），**CC BY 4.0**——随本仓库分发须署名，特此致谢 [Argmax](https://github.com/argmaxinc)；上游 pyannote segmentation 系列为 MIT。
- `RecapApp/App/speaker-diarization-coreml/`（wespeaker_v2 + pyannote_segmentation）与 `RecapApp/App/campplus-coreml/`（CAM++ 声纹）：FluidAudio 端侧声纹栈——WeSpeaker / Alibaba 3D-Speaker（CAM++）均为 **Apache-2.0**；运行期下载源为 HF（镜像 hf-mirror，见 `FluidAudioEngine.swift`）。
- SenseVoice 转写等其余模型为运行期按需下载，不随包分发。

## 云端网关（cloud/）

- Cloudflare Workers + TypeScript；运行时依赖 `jose`（MIT）、`ws`（MIT，仅本地验证脚本）。
- 网关不含任何用户内容存储；密钥全部为 Workers secrets。

## 商标

- "Recap"、产品图标与本文档中的厂商名称（DeepSeek / 通义千问 / 智谱 GLM / Kimi / 豆包 / OpenAI / Anthropic / Google 等）分属各自所有者，仅作互操作性描述。
