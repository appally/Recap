# 字体系统化重设计实施计划

## 方向（2026-08-01 已与用户锁定）
- **路线**：仅做 SF Pro 系统化，不引入阅读衬线体。90% 的"高级干净"来自纪律收敛。
- **英雄字**：首页「纪要」32 bold → **28 semibold**。
- **病根**：368 处 ad-hoc `.font(.system(size:))` vs 50 处 token（13% 采用）；22 种点数；31 处 lineSpacing + 32 处 tracking 全是魔法数；`AskMarkdownText` 自建平行字体系统；`recapCeladon` 已别名到 `recapInk`（91 处遗留债）。
- **目标终态**：13 个语义 token + `Tracking`/`Leading` 枚举 + 三档文字色；零裸 `.font(.system(size:))`（Image SF Symbol sizing 除外）。

## 设计原则
1. 少即高级——22 尺寸 → 13 语义角色，每档不可替代。
2. 正文是主角——阅读正文统一 16pt / ~1.45 行高；UI chrome 让位。
3. 比例非魔法数——行距/字距按角色派生，token 化。
4. 三档文字色——primary/secondary/tertiary 透明度固定。
5. 数字一律等宽——时间/时长/计数全 tabular figure。

---

## P0：地基（additive，零破坏，1 文件 + 1 全局 rename）

### P0-1 新增 13 字体 token（DesignSystem.swift，在 `extension Font` 内新增，旧 token 暂留并存）
```swift
public extension Font {
    // MARK: - 展示层
    /// 罕用大展示（保留位）。
    static let recapDisplay = Font.system(size: 34, weight: .semibold, design: .default).leading(.tight)
    /// 英雄字：首页「纪要」、空态标题、设置页英雄。28 semibold，克制现代。
    static let recapHero = Font.system(size: 28, weight: .semibold, design: .default).leading(.tight)

    // MARK: - 标题层
    /// 文档标题：笔记自身标题，需存在感（原 18 bold → 22 semibold）。
    static let recapTitle = Font.system(size: 22, weight: .semibold, design: .default).leading(.tight)
    /// 卡片/栏标题：会议卡标题、滚动态顶栏、Sheet 标题。17 semibold。
    static let recapTitleS = Font.system(size: 17, weight: .semibold, design: .default)
    /// 内联小标题：议题标题、区段内联标题、行强调。15 semibold。
    static let recapHeading = Font.system(size: 15, weight: .semibold, design: .default)

    // MARK: - 眉标
    /// 段首眉标（今天/昨天/区段名）：12 semibold，配 Tracking.eyebrow 正字距。
    static let recapEyebrow = Font.system(size: 12, weight: .semibold, design: .default)

    // MARK: - 正文层
    /// 阅读正文：转写、纪要摘要、Markdown 正文。16 regular。
    static let recapBody = Font.system(size: 16, weight: .regular, design: .default)
    /// 次正文：项目符号、议程、用户气泡、卡片预览。15 regular。
    static let recapBodyS = Font.system(size: 15, weight: .regular, design: .default)
    /// 润色行（有别于原话时）：16 semibold（与 recapBody 同尺寸，仅字重升级）。
    static let recapPolished = Font.system(size: 16, weight: .semibold, design: .default)
    /// LIVE/原话行：16 medium。
    static let recapTranscript = Font.system(size: 16, weight: .medium, design: .default)

    // MARK: - 元信息层
    /// 元信息：日期·时长文本、说话人名、说明文。13 regular。
    static let recapMeta = Font.system(size: 13, weight: .regular, design: .default)
    /// 数字等宽：时间戳、时长、计数、行内代码。13 regular mono + tabular。
    static let recapMono = Font.system(size: 13, weight: .regular, design: .monospaced).monospacedDigit()
    /// 徽标：状态胶囊、计数徽标。11 semibold。
    static let recapCaption = Font.system(size: 11, weight: .semibold, design: .default)
}
```

### P0-2 新增 Tracking / Leading 枚举（DesignSystem.swift）
```swift
public enum Tracking {
    public static let display: CGFloat = -0.6
    public static let title: CGFloat = -0.3
    public static let titleS: CGFloat = -0.2
    public static let heading: CGFloat = -0.15
    public static let body: CGFloat = -0.1
    public static let eyebrow: CGFloat = 1.4   // 眉标/小帽字正距
    public static let caption: CGFloat = 0.2
    public static let none: CGFloat = 0
}

public enum Leading {
    public static let tight: CGFloat = 2       // 标题/单行
    public static let body: CGFloat = 5        // 16pt 阅读正文 ≈1.45x
    public static let relaxed: CGFloat = 6.5   // 仅 TL;DR 高管摘要留白
}
```
迁移规则：**仅替换已存在的魔法数**——原无 tracking 的调用点不加新 tracking，避免无谓 churn。

### P0-3 recapCeladon → recapInk（91 处，机械 rename）
- 全工程 `recapCeladon` → `recapInk`（值已等价，零视觉变化）。
- 删 `DesignSystem.swift:38-41` 别名定义 + 注释。
- 涉及 `Color.recapCeladon` 与裸 `recapCeladon`（含 `.opacity(...)` 用法，替换后语义不变）。

### P0-4 验证
`xcodegen generate && xcodebuild -scheme RecapApp -destination 'platform=iOS Simulator,name=iPhone 16' build` 通过。

---

## P1：418 处调用点迁移（旧 token 50 + ad-hoc 368，按文件逐个 build）

### 迁移映射表（ad-hoc size/weight → token；**需上下文消歧**，非纯 sed）
| 现状 size/weight | → token | 备注 |
|---|---|---|
| 32 bold / 28-36 bold·semi（hero/settings 英雄） | `recapHero` | 28 semibold 统一 |
| 34 semibold | `recapDisplay` | 罕用 |
| 22-24 semibold·bold（笔记标题/note payload 标题） | `recapTitle` | **22 semibold 增存在感** |
| 18 bold·semi / 17 bold·semi（区段标题/card/sticky/sheet 标题） | `recapTitleS` | 18→17 |
| 15.5-15 semibold（topic/ASR toggle/heading） | `recapHeading` | 15.5→15 |
| 16 semibold（sticky/tab-active/CTA/md H3） | `recapTitleS` 或 `recapBody.weight(.semibold)` | 按上下文 |
| 16 medium（tab-inactive/transcript） | `recapTranscript` | |
| 16 regular（md body/assistant/TLD） | `recapBody` | 16.5→16 |
| 15 medium（task） | `recapBodyS.weight(.medium)` | |
| 15 regular / 14 regular（bullet/agenda/bubble/preview） | `recapBodyS` | 14→15 |
| 13 regular·semi·medium（meta/speaker/thinking） | `recapMeta` / `.weight(.semibold)` / `.weight(.medium)` | |
| 13 mono / 12 mono（timestamp/duration/count） | `recapMono` | 12→13 |
| 12 semibold **+ tracking**（区段眉标） | `recapEyebrow` + `Tracking.eyebrow` | 消歧点① |
| 12 semibold **无 tracking / 胶囊内**（整理中/count） | `recapCaption` | 消歧点① |
| 12 regular（footnote/disclaimer） | `recapMeta` | 12→13 |
| 11 semibold（草稿/badge/assignee/count） | `recapCaption` | 统一 11/12 徽标 |
| 9-10（极小） | `recapCaption` 或保留 | 罕见 |

**消歧点①**：12 semibold 同时用于「眉标」（配正字距）和「徽标」（胶囊内）。迁移时看是否带 `.tracking(1.x)` / 是否在 Capsule 内：眉标→`recapEyebrow`，徽标→`recapCaption`。

### tracking / lineSpacing 同步迁移
- `.tracking(-0.5~-0.8)` → `.tracking(Tracking.display)`
- `.tracking(-0.2~-0.3)` → `.tracking(Tracking.title)` / `.titleS`
- `.tracking(-0.1~-0.15)` → `.tracking(Tracking.heading)` / `.body`
- `.tracking(1.2~1.4)` → `.tracking(Tracking.eyebrow)`
- `.lineSpacing(5~6.5)` → `.lineSpacing(Leading.body)` / `.relaxed`
- `.lineSpacing(2~3)` → `.lineSpacing(Leading.tight)`

### 文件顺序（按 ad-hoc 密度，每文件迁移即 build）
1. `RecapUI/MeetingNoteView.swift`（50）— 纪要/笔记核心阅读
2. `RecapUI/Settings/ASRSettingsView.swift`（30）
3. `RecapUI/Settings/SettingsComponents.swift`（23）+ `LLMSettingsView`（20）+ `MembershipSettingsView`（22）— Settings 域统一
4. `RecapUI/AgentInvokeSheet.swift`（24）+ `RecapUI/AskMarkdownText.swift`（平行系统并轨）
5. `RecapUI/TemplateSelectionSheet.swift`（22）+ `ResearchDraftSheet.swift`（12）— Sheets 统一
6. `RecapUI/SearchView.swift`（19）+ `MomentCardView.swift`（14）
7. `RecapUI/MeetingListView.swift`（14）— 首页
8. `RecapUI/Components.swift`（12）— SpeakerBlockView/ActionItemCard/TldrCard
9. 其余散落文件（Personalization/Legal/Account/Handwriting/Mermaid/AudioPlayer 等）

### P1 末：删旧 token
迁移完 418 处后，删 `DesignSystem.swift` 旧定义：`recapHeroTitle` `recapHomeBrand` `recapBrand` `recapDisplay`(旧34/已新) `recapLargeTitle` `recapH1` `recapTldr` `recapRaw` `recapTask` `recapTaskLow` `recapSection` `recapSubMeta` `recapTimestamp`。删死组件字体规格：`LiveSonicCapsule` `LiveReadyMark`、`isCompact` 波形 caption。

---

## P2：品味升级（收敛后打磨）
- **笔记标题存在感**：`MeetingNoteView.swift` 笔记标题 `recapH1`(18 bold) → `recapTitle`(22 semi)；滚动态 sticky 保持 `recapTitleS`(17)，形成 22→17 层级。
- **tabular figure 全量**：所有时间/时长/计数/版本号统一 `recapMono` + `.monospacedDigit()`，消除跳动。
- **separator/dimming 统一**：`·` 分隔符固定 `recapTea.opacity(0.6)`；AI 声明/禁用态固定 `recapTea.opacity(0.6)`；转写非当前段 `recapInk.opacity(0.92/0.62)` 抽成 `transcriptDim` 状态色。修 0.55/0.6/0.65/0.85/0.9 漂移。
- **圆点基线对齐**：`bulletRow` 的 `Circle().padding(.top, 7)` 魔法数 → `FirstBaseline` 对齐或按字号计算的 alignment guide。

---

## 验证
- 每文件迁移后 `xcodegen generate && xcodebuild ... build` 通过。
- 关键屏视觉回归（模拟器截图对比）：首页 / 转写 / 纪要总结 / 纪要笔记 / 设置 / Ask 对话 / Sheet。
- 全量 grep 复核：`grep -rn "\.font(\.system(size:" RecapApp/ --include="*.swift"` 仅剩 Image SF Symbol sizing（无 .font 修饰的 Image 不计）；`recapCeladon` 归零。
- Dynamic Type 抽查：设置大字号下首页/纪要无截断。

## 风险与回退
- **风险①**：尺寸变化（hero 32→28、标题 18→17/22）改变视觉密度。缓解：P1 按文件迁移可逐屏 review；hero/标题改动集中在 P1 早期即可定调。
- **风险②**：12-semibold 眉标/徽标消歧误判。缓解：迁移时逐处看上下文，不批量 sed。
- **回退**：P0 additive，可独立回退；P1 按文件 commit，可逐文件 revert。
