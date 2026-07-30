import SwiftUI

/// 声纹（生物识别）**单独同意页**（PIPL §28 敏感个人信息）。
///
/// 首次「标记我」时弹出，独立 UI、不与麦克风权限/隐私政策捆绑；
/// 显式按钮取得同意（不靠行为推定）。「暂不」=拒绝，标记我不可用（优雅降级）。
struct VoiceprintConsentSheet: View {
    /// 用户点「允许并标记」：调用方据此 `VoiceprintConsent.granted = true` 并完成登记。
    let onAllow: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(spacing: Spacing.md) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.recapCinnabar)
                    Text("用声纹跨会议认出你")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.recapInk)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    point("waveform", "收集什么",
                          "从你的会议录音提取声纹数学向量（256 维，无法还原成声音或语音内容）。")
                    point("person.crop.circle.badge.questionmark", "用途",
                          "跨会议认出「这是你」，在转写与纪要中标记为「我」，关联你的发言与待办。")
                    point("hand.raised", "非必要",
                          "这不是 App 基础功能；拒绝不会影响录音、转写或纪要。")
                    point("lock.fill", "存储与去向",
                          "仅保存在本机，不上传云端、不分享给任何第三方。")
                    point("trash", "可随时撤回",
                          "在「设置 → 个性化」可删除全部声纹，删除后本功能停用。")
                }

                Text("这是对生物识别信息的单独同意，与你此前授予的麦克风录音权限相互独立。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
                    .lineSpacing(2)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.sm) {
                Button {
                    onAllow()
                } label: {
                    Text("允许并标记")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.recapInk,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(RecapPressStyle())

                Button {
                    dismiss()
                } label: {
                    Text("暂不")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.recapTea)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(RecapPressStyle())
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private func point(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapCinnabar)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.recapTea)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
