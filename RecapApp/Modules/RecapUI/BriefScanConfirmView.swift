import SwiftUI
import RecapModels

/// 扫描识别后的一屏确认：可删改议程 / 切换「当作上场遗留」。
struct BriefScanConfirmView: View {
    @Binding var isPresented: Bool
    let rawText: String
    var initialRole: BriefRole = .agenda
    var onConfirm: (BriefParseResult, BriefRole, String) -> Void

    @State private var role: BriefRole = .agenda
    @State private var agenda: [AgendaItem] = []
    @State private var openItems: [OpenItem] = []
    @State private var suggestedTitle: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Picker("用途", selection: $role) {
                    Text("当作议程").tag(BriefRole.agenda)
                    Text("当作上场遗留").tag(BriefRole.priorMinutes)
                }
                .pickerStyle(.segmented)
                .onChange(of: role) { _, newRole in
                    reparse(as: newRole)
                }

                if let suggestedTitle, !suggestedTitle.isEmpty {
                    Text(suggestedTitle)
                        .font(.recapTitleS)
                        .foregroundStyle(Color.recapInk)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        if role == .agenda {
                            ForEach(Array(agenda.enumerated()), id: \.element.id) { index, item in
                                editableRow(
                                    indexLabel: "\(item.order)",
                                    title: item.title,
                                    subtitle: item.ownerHint
                                ) {
                                    agenda.remove(at: index)
                                    renumberAgenda()
                                }
                            }
                        } else {
                            ForEach(Array(openItems.enumerated()), id: \.element.id) { index, item in
                                editableRow(
                                    indexLabel: "○",
                                    title: item.text,
                                    subtitle: item.ownerHint
                                ) {
                                    openItems.remove(at: index)
                                }
                            }
                        }
                    }
                }

                if agenda.isEmpty && openItems.isEmpty {
                    Text("未识别出条目，可返回改用粘贴。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapOchre)
                }

                Button {
                    let parse = BriefParseResult(
                        agenda: role == .agenda ? agenda : [],
                        openItems: role == .priorMinutes ? openItems : (role == .agenda ? [] : openItems),
                        entityHints: collectHints(),
                        suggestedTitle: suggestedTitle
                    )
                    onConfirm(parse, role, rawText)
                    isPresented = false
                } label: {
                    Text("确认并使用")
                        .font(.recapTitleS)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            (agenda.isEmpty && openItems.isEmpty) ? Color.recapTea : Color.recapInk,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(agenda.isEmpty && openItems.isEmpty)
            }
            .padding(Spacing.xl)
            .background(Color.recapBg.ignoresSafeArea())
            .navigationTitle(role == .agenda ? "识别为议程" : "识别为遗留")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
            }
            .onAppear {
                role = initialRole
                reparse(as: initialRole)
            }
        }
    }

    private func editableRow(indexLabel: String,
                             title: String,
                             subtitle: String?,
                             onDelete: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(indexLabel)
                .font(.recapMono)
                .foregroundStyle(Color.recapInk)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapInk)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.recapTea.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private func reparse(as role: BriefRole) {
        let parse = BriefParser.parseText(rawText, role: role)
        agenda = parse.agenda
        openItems = parse.openItems
        suggestedTitle = parse.suggestedTitle
    }

    private func renumberAgenda() {
        for i in agenda.indices {
            agenda[i].order = i + 1
        }
    }

    private func collectHints() -> [String] {
        var hints: [String] = []
        for item in agenda {
            if let o = item.ownerHint { hints.append(o) }
        }
        for item in openItems {
            if let o = item.ownerHint { hints.append(o) }
        }
        return hints
    }
}
