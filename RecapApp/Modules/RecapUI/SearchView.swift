import SwiftUI
import SwiftData
import RecapModels
import RecapLLM
import RecapPersistence

/// 独立搜索界面：以会议为聚合单元，覆盖标题/纪要/转写/待办四件套。
/// 数据来自 `RecapWorkspaceIndex.searchForUI`（复用 Agent 既有搜索引擎）。
struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var queryFieldFocused: Bool

    @State private var query = ""
    @State private var results: [MeetingSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var history: [String] = SearchHistory.load()

    @Query(sort: \Meeting.startedAt, order: .reverse) private var recentMeetings: [Meeting]

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().overlay(Color.recapTea.opacity(0.08))
            content
        }
        .background(Color.recapBg)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { queryFieldFocused = true }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            RecapToolbarIcon(RecapSymbol.back, accessibilityLabel: "返回") {
                dismiss()
            }
            HStack(spacing: Spacing.sm) {
                Image(systemName: RecapSymbol.search)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.recapTea)
                TextField("搜索会议、纪要、转写、待办", text: $query)
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapInk)
                    .focused($queryFieldFocused)
                    .submitLabel(.search)
                    .onChange(of: query) { _, new in scheduleSearch(new) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: RecapSymbol.close)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.recapTea)
                    }
                    .buttonStyle(RecapPressStyle())
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
            .recapGlassBackground()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - 内容三态

    @ViewBuilder
    private var content: some View {
        Group {
            if trimmedQuery.isEmpty {
                emptyState
            } else if results.isEmpty && isSearching {
                searchingState
            } else if results.isEmpty && hasSearched {
                noResultState
            } else {
                resultList
            }
        }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .recapValueSwap, value: contentState)
    }

    /// 搜索内容四态：仅整态切换时交叉淡入，逐字输入期间不动画（避免抖动）。
    private enum ContentState: Equatable {
        case idle, searching, noResult, results
    }

    private var contentState: ContentState {
        if trimmedQuery.isEmpty { return .idle }
        if results.isEmpty && isSearching { return .searching }
        if results.isEmpty && hasSearched { return .noResult }
        return .results
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.sm) {
                Text("\(results.count) 场相关")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.sm)
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    MeetingSearchCard(result: result, keywords: keywords)
                        .staggerAppear(index: index, reduceMotion: reduceMotion)
                }
            }
            .padding(.bottom, Spacing.xl)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if !history.isEmpty {
                    sectionHeader("最近搜索", onClear: {
                        SearchHistory.clear()
                        history = []
                    })
                    HistoryTags(tags: history) { term in
                        query = term
                        scheduleSearch(term)
                        queryFieldFocused = true
                    }
                }
                if !recentMeetings.isEmpty {
                    sectionHeader("最近会议", onClear: nil)
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(recentMeetings.prefix(5)) { m in
                            NavigationLink(value: MeetingRoute.meeting(m.id)) {
                                RecentMeetingRow(meeting: m)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Spacing.md)
        }
    }

    private var searchingState: some View {
        VStack {
            ProgressView().tint(.recapTea)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: RecapSymbol.search)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.recapTea.opacity(0.75))
            Text("没有找到「\(trimmedQuery)」相关的内容")
                .font(.recapBodyS)
                .foregroundStyle(Color.recapTea)
            Text("试试换个关键词，或用更短的词")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }

    // MARK: - 搜索调度（debounce 200ms）

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }
        isSearching = true
        let snapshot = trimmed
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await runSearch(snapshot)
        }
    }

    @MainActor
    private func runSearch(_ q: String) async {
        let index = RecapWorkspaceIndex(modelContainer: modelContext.container)
        let r = await index.searchForUI(query: q)
        if Task.isCancelled { return }
        results = r
        hasSearched = true
        isSearching = false
        if !r.isEmpty {
            SearchHistory.add(q)
            history = SearchHistory.load()
        }
    }

    /// 高亮用：用户原始查询按非字母数字切分（中文连续汉字保持成词）。
    private var keywords: [String] {
        trimmedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, onClear: (() -> Void)?) -> some View {
        HStack {
            Text(title)
                .font(.recapMeta.weight(.semibold))
                .foregroundStyle(Color.recapTea)
            Spacer()
            if let onClear {
                Button("清除", action: onClear)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }
        }
    }
}

// MARK: - 结果卡片

private struct MeetingSearchCard: View {
    let result: MeetingSearchResult
    let keywords: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题区：跳总结概览
            NavigationLink(value: MeetingRoute.meeting(result.meetingId)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.title)
                        .font(.recapTitleS)
                        .foregroundStyle(Color.recapInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(result.startedAt, format: .dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                        if !result.speakerNames.isEmpty {
                            Text("· " + result.speakerNames.prefix(3).joined(separator: " "))
                                .font(.recapMeta)
                                .foregroundStyle(Color.recapTea)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            // 命中预览（首条）：跳精确位
            if let preview = result.hits.first {
                NavigationLink(value: route(for: preview)) {
                    HighlightedText(text: preview.snippet, keywords: keywords)
                        .font(.recapMeta)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            HitChips(countByKind: result.countByKind)

            // 其余命中片段：各自跳精确位
            ForEach(Array(result.hits.dropFirst().prefix(2))) { hit in
                NavigationLink(value: route(for: hit)) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(hit.kind.label)
                            .font(.recapCaption)
                            .foregroundStyle(Color.recapTea)
                            .frame(width: 26, alignment: .leading)
                        HighlightedText(text: hit.snippet, keywords: keywords)
                            .font(.recapMeta)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.recapPaper,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(Color.recapTea.opacity(0.08), lineWidth: 0.5)
        )
        .recapCardShadow()
    }

    /// 命中片段 -> 跳转路由：转写/待办跳时间点，笔记跳该篇，标题/纪要跳总结。
    private func route(for hit: SearchHit) -> MeetingRoute {
        switch hit.kind {
        case .transcript, .actionItem:
            return .meetingAt(result.meetingId, scrollStart: hit.timeAnchor, noteTarget: nil)
        case .note:
            return .meetingAt(result.meetingId, scrollStart: nil, noteTarget: hit.noteTarget ?? .summary)
        case .summary, .title:
            return .meeting(result.meetingId)
        }
    }
}

// MARK: - 关键词高亮（命中词 ink 深，其余 tea 灰——靠深浅做层次，不用朱砂硬色）

struct HighlightedText: View {
    let text: String
    let keywords: [String]

    var body: some View {
        Text(build())
    }

    private func build() -> AttributedString {
        var attr = AttributedString(text)
        attr.foregroundColor = .recapTea
        for kw in keywords {
            guard !kw.isEmpty else { continue }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let r = text.range(of: kw, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                let lower = attr.index(attr.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: r.lowerBound))
                let upper = attr.index(attr.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: r.upperBound))
                attr[lower..<upper].foregroundColor = .recapInk
                searchStart = r.upperBound
            }
        }
        return attr
    }
}

// MARK: - 命中类型 chips

private struct HitChips: View {
    let countByKind: [SearchHitKind: Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SearchHitKind.allCases, id: \.self) { kind in
                if let n = countByKind[kind], n > 0 {
                    Text(n > 1 ? "\(kind.label)×\(n)" : kind.label)
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.recapTea.opacity(0.10), in: Capsule())
                }
            }
        }
    }
}

// MARK: - 空态：最近会议行 / 历史标签

private struct RecentMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.recapBodyS.weight(.medium))
                .foregroundStyle(Color.recapInk)
                .lineLimit(1)
            if let tldr = meeting.tldrPreview {
                Text(tldr)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(Color.recapPaper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(Color.recapTea.opacity(0.08), lineWidth: 0.5)
        )
        .recapCardShadow()
    }
}

private struct HistoryTags: View {
    let tags: [String]
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button { onTap(tag) } label: {
                        Text(tag)
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.recapTea.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(RecapPressStyle())
                }
            }
        }
    }
}

// MARK: - 历史搜索词持久化

enum SearchHistory {
    static let key = "recap.searchHistory.v1"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var arr = load().filter { $0 != trimmed }
        arr.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(arr.prefix(20)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
