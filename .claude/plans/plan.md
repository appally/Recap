# P0 实现方案：个性化设置去死设置、接通输出偏好

## 目标与范围
把 PersonalizationSettingsView 里三块死设置处置干净，让整页"诚实"（每项都真生效）：

- **内容侧重 + 自定义指令** → 合并为一个自由文本**「输出偏好」**框，接通 prompt 注入。两者本质是同一件事的生硬拆分（全局输出指导），模板已覆盖按会议的内容结构，故合并为"全局输出风格层"。
- **记忆**（toggle + 管理记忆占位页）→ **整块砍除**。纯虚构（无累积/存储/检索），显式身份框已诚实覆盖"记住偏好"。
- 一并清理因此变成死代码的 `appendText`、`PlaudChipButton`、`MemoryManagementView`。

**关键简化（注入层零改动）**：`makeUserPrompt` 现为 `if let profile = userProfile?.promptSummary { parts.append(profile) }`。只要让 `UserProfile.promptSummary` 同时产出【我的身份】+【输出偏好】两块，则 `AgentSkillRunner` / `SkillNoteWriter` / `RunSkillAgentTool` / `SkillsSheet` / 注入签名**全部不动**。caching 契约依旧（user-payload 侧，不碰 `preamble`/`systemPrompt`）。

## 一、扩展 `UserProfile`（RecapModels/UserProfile.swift）
加一个 `outputPreference: String` 字段，与 `aboutMe` 并列：
- `init(aboutMe:outputPreference:)`
- `isEmpty`：两者均空
- `promptSummary`：先 `【我的身份】` 块（aboutMe 非空时），再 `【输出偏好】` 块（outputPreference 非空时），`\n\n` 连接；皆空返回 nil
- `static current`：多读一个 key `recap.output_pref`

（UI 仍是两个独立框/两个 @AppStorage key，模型层合并为一个值产出组合块。）

## 二、UI（PersonalizationSettingsView.swift）
- **删** `@AppStorage`：`recap_content_focus` / `recap_custom_instructions` / `recap_use_memory`
- **加** `@AppStorage("recap.output_pref") private var outputPref: String = ""`
- **删** section：`contentFocusSection` / `customInstructionsSection` / `memorySection`
- **加** `outputPreferenceSection`：`PlaudInputBox` 绑定 `outputPref`；标题"输出偏好"；副标题"全局风格与侧重，适用于所有会议；具体结构仍由模板决定。"；placeholder 给具体示例（"希望 Recap 如何输出？如：简明直接、务必列出待办与截止日期、标注风险与待确认事项。"）--解决"不知道写什么"
- body：`identitySection` + `outputPreferenceSection`
- **删死代码**：`appendText`、`PlaudChipButton`、`MemoryManagementView`（核实仅本文件用、仅服务于被删的 chip/记忆）
- **留**：`PlaudInputBox`（身份 + 输出偏好两框共用）

## 三、测试（RecapLLMTests/UserProfileInjectionTests.swift）
更新为覆盖双块：
- 身份+输出偏好都在 → 两块均出现
- 仅输出偏好 → 只有【输出偏好】，无【我的身份】
- 皆空 → 不注入
- caching 契约：不进 system 前缀（沿用原断言）

## 不改（零改动，已核实）
`AgentSkillRunner.makeUserPrompt/run/runDetailed`、`SkillNoteWriter`、`RunSkillAgentTool`、`SkillsSheet`、`AgentSkillDocument.preamble`、`TranscriptPolisher.systemPrompt`。

## 验收
1. 填"输出偏好: 纪要简明，务必列待办" → 生成纪要时 LLM 收到【输出偏好】块并据以裁剪；
2. 身份/输出偏好皆空 → 纪要行为与现状一致（无回归）；
3. 页面无任何死设置、无死代码；模拟器可构建 + 测试通过。
