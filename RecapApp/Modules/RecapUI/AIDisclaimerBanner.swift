import SwiftUI

/// AI 产物顶部声明条：ochre 色块「⚠︎ AI 生成，请核实」+ 可选 cinnabar 严重警告。
///
/// 笔记层 `.note` inline 渲染、`ResearchDraftSheet` 等 AI 产物界面统一复用，
/// 与 Plaud「内容由 AI 生成，仅供参考」的诚实框架对齐，但用 Recap 的 ochre 配色更显眼。
public struct AIDisclaimerBanner: View {
    public var message: String
    /// 非空时在主声明下额外显示一行 cinnabar 严重警告（如「无来源」）。
    public var severeWarning: String?

    public init(message: String = "⚠︎ AI 生成，请核实后使用", severeWarning: String? = nil) {
        self.message = message
        self.severeWarning = severeWarning
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.recapMeta.weight(.medium))
                .foregroundStyle(Color.recapOchre)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm)
                .background(Color.recapOchre.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            if let severeWarning {
                Text(severeWarning)
                    .font(.recapCaption)
                    .foregroundStyle(Color.recapCinnabar)
            }
        }
    }
}
