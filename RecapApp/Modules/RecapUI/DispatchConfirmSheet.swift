import SwiftUI
import SwiftData
import RecapModels

/// HITL：确认后才写入 EventKit 提醒事项。
public struct DispatchConfirmSheet: View {
    public let meetingTitle: String
    public let items: [ActionItem]
    @Binding public var isPresented: Bool

    @State private var selected: Set<UUID> = []
    @State private var isRunning = false
    @State private var resultMessage: String?
    @Environment(\.modelContext) private var modelContext

    public init(meetingTitle: String, items: [ActionItem], isPresented: Binding<Bool>) {
        self.meetingTitle = meetingTitle
        self.items = items
        self._isPresented = isPresented
    }

    private var dispatchable: [ActionItem] {
        items.filter { item in
            if item.isReallyDispatched { return false }
            if item.isLowConfidence { return false }
            return true
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            if let resultMessage {
                Text(resultMessage)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapOchre)
                    .padding(.horizontal, Spacing.xl)
            }
            if dispatchable.isEmpty {
                Text("没有可分发的待办（需已确认的高置信项，或尚未真实分发的项）。")
                    .font(.recapRaw)
                    .foregroundStyle(Color.recapTea)
                    .padding(.horizontal, Spacing.xl)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: Spacing.sm) {
                        ForEach(dispatchable) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                }
                confirmButton
            }
        }
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .background(Color.recapBg.ignoresSafeArea())
        .onAppear {
            selected = Set(dispatchable.map(\.id))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("确认分发待办")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Text(meetingTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.recapTea)
                    .frame(width: 32, height: 32)
                    .background(Color.recapTea.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.xl)
    }

    private func row(_ item: ActionItem) -> some View {
        let on = selected.contains(item.id)
        return Button {
            if on { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.recapCeladon : Color.recapTea)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                        .multilineTextAlignment(.leading)
                    if let owner = item.owner {
                        Text(owner)
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.md)
            .background(
                Color.recapPaper,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var confirmButton: some View {
        Button {
            Task { await runDispatch() }
        } label: {
            Text(isRunning ? "分发中…" : "确认分发到提醒事项")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.recapCeladon, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRunning || selected.isEmpty)
        .padding(.horizontal, Spacing.xl)
    }

    private func runDispatch() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var ok = 0
        var fail = 0
        for item in dispatchable where selected.contains(item.id) {
            do {
                let id = try await ReminderDispatcher.shared.dispatch(
                    item,
                    meetingTitle: meetingTitle
                )
                item.externalReminderId = id
                item.status = .dispatched
                ok += 1
            } catch {
                fail += 1
            }
        }
        try? modelContext.save()
        resultMessage = "成功 \(ok) 条" + (fail > 0 ? "，失败 \(fail) 条" : "")
        if fail == 0, ok > 0 {
            try? await Task.sleep(for: .seconds(0.8))
            isPresented = false
        }
    }
}
