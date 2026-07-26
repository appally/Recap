import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import RecapModels

/// 资料窗路由：由父视图解释（列表场景可 no-op）。
enum MeetingKitRoute: Sendable {
    case regenerateWithBrief
    case openResearchProgress(taskId: UUID)
    case openResearchDraft(outputId: UUID)
}

/// 本场资料：空态展示添加入口；有内容时统一列表 + 右上角添加。
struct BriefSheet: View {
    @Bindable var meeting: Meeting
    @Binding var isPresented: Bool
    /// 保留参数以兼容调用方；不再用 Tab 切换，列表统一展示。
    var initialShelf: MeetingKitShelf = .incoming
    var allowsRegenerate: Bool = false
    var runningTaskId: UUID? = nil
    var onRoute: ((MeetingKitRoute) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.startedAt, order: .reverse) private var allMeetings: [Meeting]

    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteRole: BriefRole = .agenda
    @State private var showImporter = false
    @State private var showLinkPicker = false
    @State private var showScanner = false
    @State private var showScanConfirm = false
    @State private var scanRawText = ""
    @State private var statusText = ""
    @State private var isBusy = false
    @State private var showLocalDraft = false
    @State private var localDraft: ResearchDraft?

    private var brief: MeetingBrief? { meeting.brief }

    private var kitItems: [MeetingKitItem] {
        MeetingKitIndex.build(from: meeting, runningTaskId: runningTaskId)
    }

    /// 资料列表：来料 + AI 附页（不含证据/誊写跳转项）。
    private var materialItems: [MeetingKitItem] {
        kitItems.filter { $0.shelf == .incoming || $0.shelf == .derived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var hasMaterials: Bool {
        MeetingKitIndex.hasMaterials(for: meeting, runningTaskId: runningTaskId)
    }

    private var linkCandidates: [Meeting] {
        allMeetings.filter { $0.id != meeting.id && $0.phase == .review }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    if hasMaterials {
                        materialsList
                        if let brief, !brief.isEmpty {
                            structureSection(brief)
                        }
                        materialsFooter
                    } else {
                        emptyState
                    }
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapOchre)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xxxl)
            }
            .background(Color.recapBg.ignoresSafeArea())
            .navigationTitle("资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { isPresented = false }
                        .foregroundStyle(Color.recapInk)
                }
                if hasMaterials {
                    ToolbarItem(placement: .topBarTrailing) {
                        addMaterialsMenu
                    }
                }
            }
            .sheet(isPresented: $showPaste) { pasteSheet }
            .sheet(isPresented: $showLinkPicker) { linkPicker }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView(
                    onFinish: { images in
                        showScanner = false
                        Task { await handleScan(images) }
                    },
                    onCancel: { showScanner = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showScanConfirm) {
                BriefScanConfirmView(
                    isPresented: $showScanConfirm,
                    rawText: scanRawText,
                    initialRole: .agenda
                ) { parse, role, raw in
                    applyScan(parse: parse, role: role, rawText: raw)
                }
                .presentationDetents([.medium, .large])
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.pdf, .image, .plainText, .utf8PlainText, .text],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleImport(result) }
            }
            .sheet(isPresented: $showLocalDraft) {
                if let draft = localDraft {
                    ResearchDraftSheet(draft: draft, onJumpToTranscript: { _ in })
                        .presentationBackground(Color.recapBg)
                }
            }
        }
    }

    // MARK: - Empty / Filled

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("还没有资料")
                    .font(.recapH1)
                    .foregroundStyle(Color.recapInk)
                Text("议程、上场遗留或议案会成为纪要骨架；也可稍后补充。不挡开录。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionGrid
        }
    }

    private var materialsList: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(MeetingKitIndex.chipLabel(for: meeting, runningTaskId: runningTaskId))
                .font(.recapH1)
                .foregroundStyle(Color.recapInk)
            Text("本场相关材料，点开可查看。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)

            ForEach(materialItems) { item in
                materialRow(item)
            }
        }
    }

    @ViewBuilder
    private func materialRow(_ item: MeetingKitItem) -> some View {
        let row = HStack(alignment: .top, spacing: Spacing.md) {
            RecapRowIcon(
                item.systemImage,
                tint: item.shelf == .derived ? Color.recapCeladon : Color.recapInk.opacity(0.55)
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.recapTask)
                    .foregroundStyle(Color.recapInk)
                    .multilineTextAlignment(.leading)
                Text(rowSubtitle(for: item))
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }
            Spacer(minLength: 0)
            if isTappable(item) {
                Image(systemName: RecapSymbol.chevron)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.recapTea)
            }
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.recapPaper)
        )

        if isTappable(item) {
            Button { handleMaterialTap(item) } label: { row }
                .buttonStyle(RecapPressStyle())
        } else {
            row
        }
    }

    private func rowSubtitle(for item: MeetingKitItem) -> String {
        switch item.shelf {
        case .incoming:
            return "会前 · \(item.subtitle)"
        case .derived:
            return "AI · \(item.subtitle)"
        case .evidence, .canonical:
            return item.subtitle
        }
    }

    private func isTappable(_ item: MeetingKitItem) -> Bool {
        switch item.target {
        case .researchDraft, .researchTask: return true
        case .briefHome, .regenerateWithBrief: return false
        }
    }

    @ViewBuilder
    private func structureSection(_ brief: MeetingBrief) -> some View {
        if !brief.agenda.isEmpty || !brief.openItems.isEmpty {
            currentBrief(brief)
        }
    }

    @ViewBuilder
    private var materialsFooter: some View {
        if brief != nil, !(brief?.isEmpty ?? true) {
            Button("清空会前资料") { clearBrief() }
                .font(.recapMeta)
                .foregroundStyle(Color.recapCinnabar)
        }
        if allowsRegenerate {
            Button {
                onRoute?(.regenerateWithBrief)
            } label: {
                Text("按资料重生成纪要")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .background(Color.recapPaper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
            .buttonStyle(RecapPressStyle())
        }
    }

    private var addMaterialsMenu: some View {
        Menu {
            Button {
                if DocumentScannerView.isSupported {
                    showScanner = true
                } else {
                    statusText = "此设备不支持文档扫描，请改用导入或粘贴"
                }
            } label: {
                Label("扫描议程", systemImage: RecapSymbol.scan)
            }
            Button {
                pasteText = ""
                pasteRole = .agenda
                showPaste = true
            } label: {
                Label("粘贴文本", systemImage: RecapSymbol.paste)
            }
            Button {
                showImporter = true
            } label: {
                Label("导入文件", systemImage: RecapSymbol.importFile)
            }
            Button {
                showLinkPicker = true
            } label: {
                Label("关联上场", systemImage: RecapSymbol.linkPrior)
            }
        } label: {
            Image(systemName: RecapSymbol.add)
                .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
        }
        .accessibilityLabel("添加资料")
    }

    private func handleMaterialTap(_ item: MeetingKitItem) {
        switch item.target {
        case .researchDraft(let id):
            if let onRoute {
                onRoute(.openResearchDraft(outputId: id))
            } else if let draft = meeting.outputs.first(where: { $0.id == id })?.researchDraftPayload {
                localDraft = draft
                showLocalDraft = true
            }
        case .researchTask(let id):
            if let onRoute {
                onRoute(.openResearchProgress(taskId: id))
            } else {
                statusText = "请打开该场会议后查看调研进度"
                _ = id
            }
        case .briefHome, .regenerateWithBrief:
            break
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.md) {
            actionCard(title: "扫描议程", subtitle: "纸质材料一页", systemImage: RecapSymbol.scan) {
                if DocumentScannerView.isSupported {
                    showScanner = true
                } else {
                    statusText = "此设备不支持文档扫描，请改用导入或粘贴"
                }
            }
            actionCard(title: "粘贴文本", subtitle: "议程 / 遗留", systemImage: RecapSymbol.paste) {
                pasteText = ""
                pasteRole = .agenda
                showPaste = true
            }
            actionCard(title: "导入文件", subtitle: "PDF / 图片 / 文本", systemImage: RecapSymbol.importFile) {
                showImporter = true
            }
            actionCard(title: "关联上场", subtitle: "拉取未完成待办", systemImage: RecapSymbol.linkPrior) {
                showLinkPicker = true
            }
        }
        .opacity(isBusy ? 0.55 : 1)
        .disabled(isBusy)
    }

    private func actionCard(title: String,
                            subtitle: String,
                            systemImage: String,
                            destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(destructive ? Color.recapCinnabar : Color.recapCeladon)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.recapTea)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
            .background(Color.recapPaper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func currentBrief(_ brief: MeetingBrief) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if !brief.agenda.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("议程骨架")
                        .font(.recapSection)
                        .foregroundStyle(Color.recapCeladon)
                    ForEach(brief.agenda.sorted(by: { $0.order < $1.order })) { item in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                            Text("\(item.order).")
                                .font(.recapTimestamp)
                                .foregroundStyle(Color.recapTea)
                                .frame(width: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.recapRaw)
                                    .foregroundStyle(Color.recapInk)
                                if let owner = item.ownerHint, !owner.isEmpty {
                                    Text(owner)
                                        .font(.recapMeta)
                                        .foregroundStyle(Color.recapTea)
                                }
                            }
                        }
                    }
                }
            }

            if !brief.openItems.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("待闭环")
                        .font(.recapSection)
                        .foregroundStyle(Color.recapOchre)
                    ForEach(brief.openItems) { item in
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Text(item.resolution == "closed" ? "✓" : "○")
                                .font(.recapMeta)
                                .foregroundStyle(item.resolution == "closed" ? Color.recapCeladon : Color.recapOchre)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                    .font(.recapRaw)
                                    .foregroundStyle(Color.recapInk)
                                if let owner = item.ownerHint, !owner.isEmpty {
                                    Text(owner)
                                        .font(.recapMeta)
                                        .foregroundStyle(Color.recapTea)
                                }
                            }
                        }
                    }
                }
            }

            if !brief.sources.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("来源")
                        .font(.recapSection)
                        .foregroundStyle(Color.recapTea)
                    ForEach(brief.sources) { source in
                        Text("\(source.role.displayName) · \(source.title)")
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                    }
                }
            }
        }
    }

    // MARK: - Paste

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Picker("角色", selection: $pasteRole) {
                    Text("议程").tag(BriefRole.agenda)
                    Text("上场纪要").tag(BriefRole.priorMinutes)
                    Text("备忘").tag(BriefRole.notes)
                }
                .pickerStyle(.segmented)

                TextEditor(text: $pasteText)
                    .font(.recapRaw)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.md)
                    .frame(minHeight: 220)
                    .background(Color.recapPaper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

                Text("每行一条议题；或粘贴含「1.」「遗留」等标题的文本。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)

                Spacer(minLength: 0)
            }
            .padding(Spacing.xl)
            .background(Color.recapBg.ignoresSafeArea())
            .navigationTitle("粘贴资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") { applyPaste() }
                        .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Link

    private var linkPicker: some View {
        NavigationStack {
            Group {
                if linkCandidates.isEmpty {
                    ContentUnavailableView(
                        "暂无可关联会议",
                        systemImage: "link.badge.plus",
                        description: Text("结束一场会后，即可把未完成待办拉进下一场资料。")
                    )
                } else {
                    List(linkCandidates) { m in
                        Button {
                            applyLinkedMeeting(m)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.recapInk)
                                Text("\(m.dateText) · 待办 \(m.todoCount)")
                                    .font(.recapMeta)
                                    .foregroundStyle(Color.recapTea)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.recapBg.ignoresSafeArea())
            .navigationTitle("关联上场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showLinkPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Actions

    private func ensureInsertedBrief() -> MeetingBrief {
        if let brief = meeting.brief { return brief }
        let created = MeetingBrief(meeting: meeting)
        modelContext.insert(created)
        meeting.brief = created
        return created
    }

    private func applyPaste() {
        let text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parse = BriefParser.parseText(text, role: pasteRole)
        let source = BriefSource(
            role: pasteRole,
            kind: .paste,
            title: "粘贴·\(pasteRole.displayName)",
            rawText: String(text.prefix(8_000))
        )
        let brief = ensureInsertedBrief()
        brief.merge(parse: parse, source: source)
        if meeting.hasProvisionalTitle, let title = parse.suggestedTitle {
            meeting.title = Meeting.refineTitle(title)
        }
        try? modelContext.save()
        statusText = parse.isEmpty ? "未识别出条目，请检查格式" : "已加入资料"
        showPaste = false
    }

    private func applyLinkedMeeting(_ prior: Meeting) {
        let parse = BriefParser.parseLinkedMeeting(prior)
        let source = BriefSource(
            role: .linkedMeeting,
            kind: .linkedMeeting,
            title: prior.title,
            linkedMeetingId: prior.id
        )
        let brief = ensureInsertedBrief()
        brief.merge(parse: parse, source: source)
        try? modelContext.save()
        statusText = parse.openItems.isEmpty
            ? "上场无未完成待办"
            : "已关联「\(prior.title)」· \(parse.openItems.count) 条遗留"
        showLinkPicker = false
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            statusText = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isBusy = true
            statusText = "正在读取…"
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isBusy = false
            }
            do {
                let text = try await BriefDocumentReader.extractText(from: url)
                let role = BriefParser.guessRole(fileName: url.lastPathComponent, textHead: text)
                let parse = BriefParser.parseText(text, role: role)
                let source = BriefSource(
                    role: role,
                    kind: .file,
                    title: url.lastPathComponent,
                    rawText: String(text.prefix(8_000))
                )
                await MainActor.run {
                    let brief = ensureInsertedBrief()
                    brief.merge(parse: parse, source: source)
                    if meeting.hasProvisionalTitle, let title = parse.suggestedTitle {
                        meeting.title = Meeting.refineTitle(title)
                    }
                    try? modelContext.save()
                    statusText = parse.isEmpty
                        ? "已导入，但未抽出条目——可改粘贴微调"
                        : "已导入\(role.displayName)·议程 \(parse.agenda.count)·遗留 \(parse.openItems.count)"
                }
            } catch {
                await MainActor.run {
                    statusText = error.localizedDescription
                }
            }
        }
    }

    private func clearBrief() {
        guard let brief = meeting.brief else {
            statusText = "尚无会前资料"
            return
        }
        brief.clearAll()
        modelContext.delete(brief)
        meeting.brief = nil
        try? modelContext.save()
        statusText = "已清空会前资料"
    }

    private func handleScan(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        isBusy = true
        statusText = "正在识别…"
        defer { isBusy = false }
        do {
            let text = try await BriefScanOCR.extractText(from: images)
            await MainActor.run {
                scanRawText = text
                showScanConfirm = true
                statusText = ""
            }
        } catch {
            await MainActor.run {
                statusText = error.localizedDescription
            }
        }
    }

    private func applyScan(parse: BriefParseResult, role: BriefRole, rawText: String) {
        let source = BriefSource(
            role: role,
            kind: .scan,
            title: role == .agenda ? "扫描议程" : "扫描上场纪要",
            rawText: String(rawText.prefix(8_000))
        )
        let brief = ensureInsertedBrief()
        brief.merge(parse: parse, source: source)
        if meeting.hasProvisionalTitle, let title = parse.suggestedTitle {
            meeting.title = Meeting.refineTitle(title)
        }
        try? modelContext.save()
        statusText = parse.isEmpty ? "扫描完成但未抽出条目" : "已加入扫描资料"
    }
}

// MARK: - Toolbar

/// 本场「资料」统一入口（LIVE / REVIEW / 列表共用）。
enum MeetingMaterialsChrome {
    static let symbolName = RecapSymbol.materials
    static let accessibilityName = "资料"
}

/// 顶栏资料入口：委托给 `RecapToolbarIcon`，保证与 Ask / 回听同规。
struct BriefToolbarButton: View {
    var hasContent: Bool = false
    var accessibilityDetail: String? = nil
    let action: () -> Void

    var body: some View {
        RecapToolbarIcon(
            MeetingMaterialsChrome.symbolName,
            hasBadge: hasContent,
            accessibilityLabel: accessibilityDetail ?? MeetingMaterialsChrome.accessibilityName,
            accessibilityHint: "查看或添加本场资料",
            action: action
        )
    }
}
