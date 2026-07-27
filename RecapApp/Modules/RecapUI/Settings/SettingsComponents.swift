import SwiftUI
import RecapModels

// MARK: - 设置页氛围背景

struct SettingsAmbientBackground: View {
    var body: some View {
        ZStack {
            Color.recapBg
            RadialGradient(
                colors: [
                    Color.recapCinnabar.opacity(0.025),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 卡片与度量

enum SettingsMetrics {
    static let hairline = Color.recapTea.opacity(0.08)
    static let separator = Color.recapTea.opacity(0.10)
    static let chevron = Color.recapTea.opacity(0.55)
    static let iconBadge: CGFloat = 32
    /// 分隔线左缩进：对齐标题起始位置（横向内边距 + 徽记宽 + 间距）。
    static let separatorInset = Spacing.lg + iconBadge + Spacing.md
    static let minRowHeight: CGFloat = 44
}

extension View {
    /// 设置页统一卡片：纸底 + 发丝描边 + 单档投影。
    /// 投影挂在形状上而非整个视图，否则正文文字也会被投影糊掉。
    func settingsCard(cornerRadius: CGFloat = Radius.card) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.recapPaper)
                .recapCardShadow()
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(SettingsMetrics.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 分组

// MARK: - 分组（Plaud 平面纸质风格，无浮雕卡片框）

struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(Color.recapTea)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                content()
            }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.recapTea.opacity(0.85))
                    .lineSpacing(3)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - 导航行

struct SettingsNavRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    var titleTint: Color = .recapInk
    var value: String? = nil
    var showChevron: Bool = true

    var body: some View {
        HStack(spacing: Spacing.md) {
            if !icon.isEmpty {
                SettingsIconBadge(systemName: icon, tint: iconTint)
            }

            Text(title)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(titleTint)

            Spacer(minLength: Spacing.sm)

            if let value {
                Text(value)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.recapValueSwap, value: value)
            }

            if showChevron {
                SettingsChevron()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 14)
        .frame(minHeight: SettingsMetrics.minRowHeight)
        .contentShape(Rectangle())
    }
}

struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.recapTea.opacity(0.45))
    }
}

/// Plaud 极简 1.5px 单色 Outline 图标（非彩色背景小方块）
struct SettingsIconBadge: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(Color.recapInk)
            .frame(width: 24, height: 24, alignment: .center)
    }
}

struct SettingsDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.recapTea.opacity(0.12))
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

// MARK: - 头像

/// 品牌渐变与首字是登录后才拿到的；访客态用素灰人像，读起来像邀请而不是身份。
struct SettingsAvatar: View {
    let account: RecapAccount
    var size: CGFloat

    var body: some View {
        ZStack {
            if account.isSignedIn {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.recapCeladon.opacity(0.9),
                                Color.recapCeladon.opacity(0.5),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(account.initials)
                    .font(.system(size: size * 0.40, weight: .bold, design: .default))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .fill(Color.recapTea.opacity(0.12))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Color.recapTea.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 行内状态提示

/// 操作回执：淡入并上浮 4pt，退场只淡出（更干脆），4 秒后自动消散。
struct SettingsInlineNotice: View {
    @Binding var message: String
    var kind: SettingsStatusPill.Kind = .info

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !message.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(kind.color)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.recapTea)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 4)),
                        removal: .opacity
                    )
                )
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(4))
                    message = ""
                }
            }
        }
        .animation(.recapNotice, value: message)
    }
}

// MARK: - 选择卡片

struct SettingsChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String? = nil
    var badgeTint: Color = .recapCeladon
    let selected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.recapCeladon.opacity(0.16) : Color.recapTea.opacity(0.08))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? Color.recapCeladon : Color.recapTea)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Spacing.sm) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.recapInk)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(badgeTint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(badgeTint.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.recapTea)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(selected ? Color.recapCeladon : Color.recapTea.opacity(0.35))
                    .padding(.top, 2)
            }
            .padding(Spacing.lg)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.recapPaper)
                    .recapCardShadow()
            }
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(
                        selected ? Color.recapCeladon.opacity(0.55) : SettingsMetrics.separator,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(SettingsPressStyle())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .recapSoft, value: selected)
        // 只在被选中时敲一次；否则同组里刚被取消的那张卡会跟着再响一次。
        .sensoryFeedback(trigger: selected) { _, isSelected in
            isSelected ? .selection : nil
        }
    }
}

// MARK: - 分段

struct SettingsSegmentedControl<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                let selected = selection == value
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .recapSoft) {
                        selection = value
                    }
                } label: {
                    Text(title)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.recapInk : Color.recapTea)
                        // 含 4pt 外框内边距后达到 44pt 最小触控目标。
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .padding(.vertical, 12)
                        .background {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(Color.recapPaper)
                                    .shadow(color: .recapShadow, radius: 6, x: 0, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(SettingsMetrics.separator, in: Capsule(style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - 状态胶囊

struct SettingsStatusPill: View {
    enum Kind {
        case ready, missing, info

        var color: Color {
            switch self {
            case .ready: return .recapCeladon
            case .missing: return .recapOchre
            case .info: return .recapTea
            }
        }
    }

    let text: String
    var kind: Kind = .info

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(kind.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(kind.color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Key 输入块

struct SettingsSecureFieldBlock: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var configured: Bool
    var onSave: () -> Void
    var onClear: (() -> Void)?

    @State private var showSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Spacer()
                SettingsStatusPill(
                    text: configured ? "已配置" : "未配置",
                    kind: configured ? .ready : .missing
                )
            }

            HStack(spacing: Spacing.sm) {
                if showSecret {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14, design: .monospaced))
                } else {
                    SecureField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14, design: .monospaced))
                }

                Button {
                    showSecret.toggle()
                } label: {
                    Image(systemName: showSecret ? "eye.slash" : "eye")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.recapTea)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
            .background(
                Color.recapBg,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            HStack(spacing: Spacing.md) {
                Button(action: {
                    Haptics.impact(.medium)
                    onSave()
                }) {
                    Text("保存")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.recapCeladon, in: Capsule())
                }
                .buttonStyle(SettingsPressStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)

                if configured, let onClear {
                    Button(role: .destructive) {
                        Haptics.impact(.medium)
                        onClear()
                    } label: {
                        Text("清除")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.recapCinnabar)
                    }
                }

                Spacer()
            }
        }
        .padding(Spacing.lg)
        .settingsCard()
    }
}

// MARK: - Press

typealias SettingsPressStyle = RecapPressStyle
