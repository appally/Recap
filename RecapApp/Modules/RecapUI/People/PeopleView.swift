import SwiftUI
import SwiftData
import RecapModels
import RecapASR

/// 人物目录页（plan 064）——「认识你的人」的一等入口：最近见面排序、未完结承诺
/// badge、命名率引导头。数据 = SpeakerDirectory 单遍聚合（onAppear 刷新，v1 无自动失效）。
public struct PeopleView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var digest = SpeakerDirectoryDigest()
    @State private var loaded = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if digest.people.isEmpty && digest.unnamedIdentityCount == 0 {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("人物")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear { refresh() }
    }

    private var list: some View {
        List {
            if digest.unnamedIdentityCount > 0 {
                namingGuideRow
            }
            ForEach(digest.people) { person in
                NavigationLink {
                    // plan 065：完整人物档案页（轨迹/双向承诺/常提术语/问 Recap）在此落地。
                    PersonProfilePlaceholder(person: person)
                } label: {
                    personRow(person)
                }
            }
        }
        .listStyle(.plain)
    }

    /// 命名率引导头：「已认识 N 位 · 还有 M 位未命名」→ 声纹设置区（ASRSettingsView 声纹 section）。
    private var namingGuideRow: some View {
        NavigationLink {
            ASRSettingsView()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.recapOchre)
                VStack(alignment: .leading, spacing: 2) {
                    Text("还有 \(digest.unnamedIdentityCount) 位未命名")
                        .font(.recapHeading)
                        .foregroundStyle(Color.recapInk)
                    Text("给 TA 起个名字，Recap 从此认识这个人")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.recapTea.opacity(0.5))
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func personRow(_ person: PersonSummary) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.recapInk.opacity(0.08))
                Text(String(person.name.prefix(1)))
                    .font(.recapHeading)
                    .foregroundStyle(Color.recapInk)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(person.name)
                    .font(.recapTitleS)
                    .foregroundStyle(Color.recapInk)
                Text("\(lastMetText(person.lastMetAt)) · 共 \(person.meetingCount) 场")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }
            Spacer()
            if person.openPromiseCount > 0 {
                Text("承诺 \(person.openPromiseCount)")
                    .font(.recapCaption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "person.2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.recapTea.opacity(0.6))
            Text("还没有认识的人")
                .font(.recapTitleS)
                .foregroundStyle(Color.recapInk)
            Text("先录一场会，会后长按说话人名字纠正一次，\nRecap 从此开始认识你见过的每个人。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
                .multilineTextAlignment(.center)
                .lineSpacing(Leading.tight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据

    private func refresh() {
        let refs = VoiceprintGallery.shared.directoryRefs()
        let built = SpeakerDirectory.build(context: modelContext, gallery: refs)
        withAnimation(.recapValueSwap) {
            digest = built
        }
        loaded = true
    }

    private func lastMetText(_ date: Date?) -> String {
        guard let date else { return "暂无同场记录" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "今天见过"
        case 1: return "昨天见过"
        case 2..<30: return "\(days) 天前见过"
        default:
            let formatted = date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
            return "\(formatted)见过"
        }
    }
}

/// plan 065 占位：人物档案页落地前的最小详情（显示聚合摘要，防止空 push）。
private struct PersonProfilePlaceholder: View {
    let person: PersonSummary

    var body: some View {
        List {
            Section {
                LabeledContent("名字", value: person.name)
                LabeledContent("同场次数", value: "\(person.meetingCount) 场")
                LabeledContent("未完结承诺", value: "\(person.openPromiseCount) 项")
            } footer: {
                Text("完整人物档案（跨会轨迹 / 双向承诺 / 常提术语 / 问 Recap）即将到来（plan 065）。")
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
