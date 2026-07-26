import SwiftUI

/// 技能 / 模板面板（参考 Plaud 的"AI 模板"系统）
/// 对生成的纪要进行二次加工：写作 / 提取 / 分析 三大类
struct SkillsSheet: View {
    @Binding var isPresented: Bool
    let meetingTitle: String

    @State private var runningSkill: String? = nil
    @State private var result: SkillResult? = nil

    struct SkillResult: Identifiable {
        let id = UUID()
        let title: String
        let preview: String
    }

    private let skillGroups: [SkillGroup] = [
        SkillGroup(
            title: "写作",
            symbol: "square.and.pencil",
            color: .recapCeladon,
            skills: [
                Skill(icon: "envelope", name: "客户跟进邮件", desc: "把会议要点转成一封对客户的礼貌邮件"),
                Skill(icon: "doc.text", name: "周报生成", desc: "按本周会议自动汇总成一份可发群的工作周报"),
                Skill(icon: "text.alignleft", name: "纪要精简", desc: "把 3 段 TL;DR 压成 1 段 100 字内可群发版"),
            ]
        ),
        SkillGroup(
            title: "提取",
            symbol: "list.bullet.rectangle",
            color: .recapCinnabar,
            skills: [
                Skill(icon: "checklist", name: "行动清单", desc: "只留「谁/做什么/何时」三要素，去掉一切废话"),
                Skill(icon: "checkmark.seal", name: "决策日志", desc: "只提取会议里所有正式拍板的决定"),
                Skill(icon: "questionmark.diamond", name: "未决问题", desc: "列出本次未达成共识、需要后续跟进的疑问"),
            ]
        ),
        SkillGroup(
            title: "分析",
            symbol: "chart.bar",
            color: .recapOchre,
            skills: [
                Skill(icon: "person.text.rectangle", name: "客户画像", desc: "从客户发言中提取关心点、决策风格、潜在诉求"),
                Skill(icon: "chart.line.uptrend.xyaxis", name: "项目进度", desc: "对比上次会议纪要，生成项目状态增量"),
                Skill(icon: "exclamationmark.triangle", name: "风险识别", desc: "从延期/资源/承诺过载中识别潜在风险"),
            ]
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header

                if runningSkill == nil, result == nil {
                    ForEach(skillGroups) { group in
                        skillGroupCard(group)
                    }
                } else if let r = result {
                    resultCard(r)
                } else {
                    runningView
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 60)
        }
        .background(Color.recapBg.ignoresSafeArea())
    }

    // MARK: 子视图

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.recapCeladon)
            VStack(alignment: .leading, spacing: 1) {
                Text("技能")
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .tracking(0.1)
                    .foregroundStyle(Color.recapInk)
                Text(meetingTitle)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .tracking(0.2)
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.recapTea)
                    .frame(width: 32, height: 32)
                    .background(
                        Color.recapTea.opacity(0.12),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func skillGroupCard(_ group: SkillGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: group.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(group.color)
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .tracking(0.5)
                    .foregroundStyle(group.color)
                Spacer()
            }
            VStack(spacing: Spacing.sm) {
                ForEach(group.skills) { skill in
                    skillRow(skill, accent: group.color)
                }
            }
        }
    }

    private func skillRow(_ skill: Skill, accent: Color) -> some View {
        Button {
            run(skill)
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                    Image(systemName: skill.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .tracking(0.1)
                        .foregroundStyle(Color.recapInk)
                    Text(skill.desc)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .tracking(0.1)
                        .lineSpacing(2)
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.recapTea.opacity(0.6))
                    .padding(.top, 10)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.md)
            .background(
                Color.recapPaper,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var runningView: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Color.recapCeladon)
            Text("正在用「\(runningSkill ?? "")」加工纪要…")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(Color.recapInk)
            Text("本机处理，无需联网")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(Color.recapTea)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func resultCard(_ r: SkillResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.recapCeladon)
                Text(r.title)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(Color.recapInk)
                Spacer()
                Button("重做") { result = nil }
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(Color.recapCeladon)
            }
            Text(r.preview)
                .font(.system(size: 15, weight: .regular, design: .default))
                .lineSpacing(5)
                .foregroundStyle(Color.recapInk)
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.recapPaper,
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                )

            HStack(spacing: Spacing.md) {
                Button { isPresented = false } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                        Text("复制")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                    }
                    .foregroundStyle(Color.recapInk)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .capsule)

                Button { isPresented = false } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                        Text("覆盖纪要")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .background(Color.recapCeladon, in: .capsule)
            }
        }
    }

    // MARK: 行为

    private func run(_ skill: Skill) {
        runningSkill = skill.name
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                runningSkill = nil
                result = SkillResult(
                    title: skill.name + " · 完成",
                    preview: previewText(for: skill)
                )
            }
        }
    }

    private func previewText(for skill: Skill) -> String {
        switch skill.name {
        case "客户跟进邮件":
            return "李总好，\n\n感谢今天会议中您对方案的反馈。我们已确认移动端投入提至 30%，并由我方在本周五前出具详细评审方案。报价口径采用单设备 420 元（含一年服务），关于 iPad 首批纳入的疑问，我方将在下周内给出明确结论后再行对接。\n\n如有其他关切，欢迎随时同步。\n\n王明\nRecap 产品"
        case "周报生成":
            return "本周进展：\n• 移动端 Q3 投入比例确定为 30% 预算（已通过）\n• 单设备报价 420 元（含一年服务）口径已对齐\n• 下周交付：移动端评审方案（李华 · 14:34）、客户报价确认（张明 · 14:35）\n\n阻塞：iPad 首批是否纳入方案，待张明下周给结论。\n\n下周计划：完成评审方案过审 + 推动客户报价签字。\n\n（基于本周 1 场会议自动汇总）"
        case "纪要精简":
            return "周会确认两件事：移动端 Q3 预算提至 30%，单台报价 420 元。下周交付评审方案与客户报价确认。详细待办与未决问题见下方。"
        case "行动清单":
            return "□ 出移动端评审方案 — 李华 — 周五前\n□ 确认客户报价 — 张明 — 14:35 待确认\n□ 整理报价对比表 — 张明 — 下周二\n□ iPad 首批纳入方案 — 张明 — 下周给结论"
        case "决策日志":
            return "① 移动端投入提至总预算 30%（14:33 张明拍板）\n② 采用「单设备 420 元」报价口径（14:32 李华拍板）"
        case "未决问题":
            return "❓ iPad 端是否纳入首批？—— 14:35 张明表示下周给结论"
        case "客户画像":
            return "角色：客户方技术负责人\n关心点：方案可落地性 + 总预算控制\n决策风格：关注单点 ROI，倾向数据说话\n潜在诉求：可能对长期服务成本敏感，可备 1-2 年的成本对比"
        case "项目进度":
            return "对比上次：移动端预算从「待定」→「30%」（✓ 推进）\n新阻塞：无\n新风险：iPad 端首批评审路径未对齐\n本周净进度：1 项决策 + 3 项新待办"
        case "风险识别":
            return "⚠ 资源风险：本周新增 3 项待办集中在李华/张明（建议拆分或延期）\n⚠ 承诺风险：周五前要出评审方案，但今天才确认预算口径（时间紧）\n⚠ 范围风险：iPad 端未拍板，可能拖到下周中"
        default:
            return "（原型占位）该技能会基于本场纪要调用对应 prompt 模板生成结果。"
        }
    }
}

// MARK: - 数据模型

struct Skill: Identifiable, Hashable {
    let id = UUID()
    let icon: String
    let name: String
    let desc: String
}

struct SkillGroup: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let symbol: String
    let color: Color
    let skills: [Skill]
}
