import SwiftUI
import SwiftData
import RecapModels
import RecapASR

/// 声纹身份轨迹查询（plan 047 Wave B / 051 扩展）：全量取会议（按开始时间倒序），
/// 内存过滤 speakers blob 中含该 voiceprintId 的会议。会议量级（百级）下开销可忽略；
/// 上千场时再考虑建 voiceprintId → meetingId 索引。
/// limit 上限与 `RecapWorkspaceIndex.scanCap`（200）同一量级假设——两处口径需同步调整。
enum VoiceprintHistory {
    struct Appearance: Identifiable {
        let id: UUID
        let title: String
        let startedAt: Date
    }

    static func appearances(
        voiceprintId: String,
        in context: ModelContext,
        excluding meetingId: UUID?,
        limit: Int = 5
    ) -> [Appearance] {
        guard !voiceprintId.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        guard let meetings = try? context.fetch(descriptor) else { return [] }
        return meetings
            .filter { meeting in
                meeting.id != meetingId
                    && meeting.speakers.contains { $0.voiceprintId == voiceprintId }
            }
            .prefix(limit)
            .map { Appearance(id: $0.id, title: $0.title, startedAt: $0.startedAt) }
    }
}

/// 说话人纠错弹层（plan 047）+ 人物中心视图（plan 051）：
/// 重命名（写回画廊终身生效）/ 合并同一个人 / 与 TA 的全部场次（可跳转）/ 问 Recap 跨会追问。
/// 设计取向：sheet + 克制（对齐 SpeakerPickerSheet / VoiceSampleRecorderSheet 形态）。
///
/// 跳转说明：sheet 不在外层 NavigationStack 层级内，`MeetingRoute` 的 navigationDestination
/// 命不中——故自带 NavigationStack + 本地 destination（只注册 `.meeting`；本 sheet 不产
/// `.meetingAt`）。若真机呈现异常，降级方案 = 行改纯展示（plans/051 STOP 条款）。
struct SpeakerDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let speaker: Speaker
    let allSpeakers: [Speaker]
    let meeting: Meeting
    let session: MeetingSession
    /// 「问 Recap：上次和 TA 聊了什么」——传说话人名，由宿主组装 prompt 并打开对话窗
    /// （plan 051：agentPrefill + autoSendInitial，模型自动走 search_meetings 两级检索）。
    let onAskRecap: (String) -> Void

    @State private var draftName: String = ""
    @State private var mergeTargetId: String?
    @State private var appearances: [VoiceprintHistory.Appearance] = []
    @State private var showMergeConfirm = false
    @State private var sheetPath = NavigationPath()

    /// 轨迹展示上限（超出折叠为「共 X 场」摘要；全量上限 200 与 scanCap 同口径）。
    private let trajectoryDisplayLimit = 5
    private let trajectoryFetchLimit = 200

    private var mergeCandidates: [Speaker] {
        allSpeakers.filter { $0.id != speaker.id }
    }

    private var mergeTarget: Speaker? {
        mergeCandidates.first { $0.id == mergeTargetId }
    }

    /// 追问护栏（plan 051 Wave B.3）：无跨会身份（voiceprintId）或名字仍是默认值的
    /// 说话人，搜不到也问不出——禁用并引导命名（同时是纠错命名的产品引导）。
    private var canAskRecap: Bool {
        guard let vp = speaker.voiceprintId, !vp.isEmpty else { return false }
        return !speaker.isUnnamed
    }

    var body: some View {
        NavigationStack(path: $sheetPath) {
            VStack(spacing: Spacing.xl) {
                header
                renameSection
                if !mergeCandidates.isEmpty {
                    mergeSection
                }
                trajectorySection
                Spacer(minLength: 0)
                doneButton
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.lg)
            .navigationDestination(for: MeetingRoute.self) { route in
                if case .meeting(let id) = route, let target = fetchMeeting(id) {
                    MeetingNoteView(meeting: target) {
                        if !sheetPath.isEmpty { sheetPath.removeLast() }
                    }
                } else {
                    Text("会议不存在").foregroundStyle(Color.recapTea)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            draftName = speaker.name == "我" ? "" : speaker.name
            if let vp = speaker.voiceprintId {
                appearances = VoiceprintHistory.appearances(
                    voiceprintId: vp, in: modelContext, excluding: meeting.id,
                    limit: trajectoryFetchLimit
                )
            }
        }
        .confirmationDialog(
            "把「\(speaker.name)」并入「\(mergeTarget?.name ?? "")」？",
            isPresented: $showMergeConfirm,
            titleVisibility: .visible
        ) {
            Button("合并（保留「\(mergeTarget?.name ?? "")」）") {
                if let target = mergeTarget {
                    session.mergeSpeaker(speaker, into: target)
                    Haptics.notify(.success)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("两段的声纹将合并为一个人，今后所有会议自动认出合并后的身份。")
        }
    }

    private func fetchMeeting(_ id: UUID) -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.recapCinnabar)
            Text(speaker.name)
                .font(.recapTitle)
                .foregroundStyle(Color.recapInk)
            if speaker.voiceprintId != nil {
                Text("声纹身份已建立——改名或合并后，今后会议自动沿用。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .multilineTextAlignment(.center)
            } else {
                Text("本场分离未启用声纹身份，改名仅对本场生效。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var renameSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("称呼")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            HStack(spacing: Spacing.md) {
                TextField("例如：王工", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.recapBody)
                    .foregroundStyle(Color.recapInk)
                    .onSubmit(applyRename)
                Button {
                    applyRename()
                } label: {
                    Text("保存")
                        .font(.recapBody.weight(.medium))
                        .foregroundStyle(canRename ? Color.recapInk : Color.recapTea.opacity(0.4))
                }
                .buttonStyle(RecapPressStyle())
                .disabled(!canRename)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, Spacing.md)
            .background(
                Color.recapInk.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    private var canRename: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != speaker.name
    }

    private func applyRename() {
        guard canRename else { return }
        session.renameSpeaker(speaker, to: draftName)
        Haptics.notify(.success)
        dismiss()
    }

    private var mergeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("其实是同一个人")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            Menu {
                ForEach(mergeCandidates) { candidate in
                    Button(candidate.name) { mergeTargetId = candidate.id }
                }
            } label: {
                HStack {
                    Text(mergeTarget?.name ?? "选择要并入的发言人")
                        .font(.recapBody)
                        .foregroundStyle(mergeTarget == nil ? Color.recapTea : Color.recapInk)
                    Spacer()
                    Image(systemName: RecapSymbol.chevron)
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea.opacity(0.75))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, Spacing.md)
                .background(
                    Color.recapInk.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            if mergeTarget != nil {
                Button {
                    showMergeConfirm = true
                } label: {
                    Text("合并")
                        .font(.recapBody.weight(.medium))
                        .foregroundStyle(Color.recapCinnabar)
                }
                .buttonStyle(RecapPressStyle())
            }
        }
    }

    /// 与 TA 的全部场次（plan 051）：前 5 场可跳转 + 「共 X 场」摘要 + 问 Recap 跨会追问。
    @ViewBuilder
    private var trajectorySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("与 TA 的会议")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            if speaker.voiceprintId == nil {
                Text("本场未启用声纹身份，暂无跨会议记录。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
            } else if appearances.isEmpty {
                Text("这是声纹画廊首次认出 TA。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
            } else {
                ForEach(appearances.prefix(trajectoryDisplayLimit)) { item in
                    NavigationLink(value: MeetingRoute.meeting(item.id)) {
                        HStack {
                            Text(item.title)
                                .font(.recapBody)
                                .foregroundStyle(Color.recapInk)
                                .lineLimit(1)
                            Spacer()
                            Text(item.startedAt.formatted(.dateTime.month().day()))
                                .font(.recapMeta)
                                .foregroundStyle(Color.recapTea)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                if appearances.count > trajectoryDisplayLimit {
                    Text("共 \(appearances.count) 场——向 TA 提问可跨全部场次检索")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea.opacity(0.75))
                }
            }
            askRecapButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var askRecapButton: some View {
        if canAskRecap {
            Button {
                let name = speaker.name
                dismiss()
                onAskRecap(name)
            } label: {
                Label("问纪要：上次和 TA 聊了什么", systemImage: RecapSymbol.ask)
                    .font(.recapBody.weight(.medium))
                    .foregroundStyle(Color.recapInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Color.recapInk.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .buttonStyle(RecapPressStyle())
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("问纪要：上次和 TA 聊了什么", systemImage: RecapSymbol.ask)
                    .font(.recapBody)
                    .foregroundStyle(Color.recapTea.opacity(0.4))
                Text("先为 TA 命名（声纹身份建立后），我才能跨会议找到 TA。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
            }
        }
    }

    private var doneButton: some View {
        Button {
            dismiss()
        } label: {
            Text("完成")
                .font(.recapTitleS)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Color.recapInk,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(RecapPressStyle())
    }
}
