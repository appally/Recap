import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RecapModels
import RecapASR

/// 外部音频导入（plan 046）：选文件 → 确认（文件名/时长/额度提示）→ 转码 16k PCM 落盘 →
/// 建 `.processing` 会议 → 导航进会议页，由 `processImportedAudio` 自动跑首转+纪要管线。
///
/// 编排参考 `VoiceSampleEnroller` 的阶段机；转码在 `Task.detached`（纯 CPU，
/// 1h 音频秒级完成，但避免卡主线程）。
@MainActor
private final class MeetingImporterModel: ObservableObject {
    enum Phase: Equatable {
        case picking
        case confirming
        case importing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .picking
    /// 待导入文件（已 startAccessingSecurityScopedResource，取消/失败时负责 stop）。
    private(set) var sourceURL: URL?
    @Published private(set) var fileName: String = ""
    @Published private(set) var estimatedDuration: Double?

    private var securityScoped = false

    var durationText: String? {
        guard let estimatedDuration, estimatedDuration > 0 else { return nil }
        let m = Int(estimatedDuration) / 60
        let s = Int(estimatedDuration) % 60
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分 \(s) 秒"
    }

    func pick(url: URL) {
        releaseAccess()
        securityScoped = url.startAccessingSecurityScopedResource()
        sourceURL = url
        fileName = url.deletingPathExtension().lastPathComponent
        estimatedDuration = nil
        phase = .confirming
        // 时长仅用于确认页展示；读不出不阻断导入（转码后回填真实时长）
        Task { [weak self] in
            guard let self, let url = self.sourceURL else { return }
            let d = await AudioImporter.estimateDuration(source: url)
            guard self.phase == .confirming else { return }
            self.estimatedDuration = d
        }
    }

    /// 确认导入：建会 → 后台转码落盘 → 回填时长/来源 → 交给调用方导航。
    func confirm(modelContext: ModelContext) async -> UUID? {
        guard let url = sourceURL else { return nil }
        phase = .importing

        let title = String(fileName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let meeting = Meeting(
            title: title.isEmpty ? "导入的音频" : title,
            startedAt: createdAt(of: url) ?? .now,
            durationSeconds: 0,
            phase: .processing,
            speakers: []
        )
        modelContext.insert(meeting)
        let meetingId = meeting.id

        do {
            let destination: URL
            do {
                destination = try MeetingAudioStore.audioURL(meetingId: meetingId)
            } catch {
                throw AudioImportError.writeFailed
            }
            // 转码纯 CPU：脱离 MainActor，security-scoped 访问保持到转码结束
            let result = try await Task.detached(priority: .userInitiated) {
                try AudioImporter.transcode(source: url, destination: destination)
            }.value
            meeting.audioPath = MeetingAudioStore.relativeAudioPath(meetingId: meetingId)
            meeting.durationSeconds = result.durationSeconds
            meeting.audioSource = .imported
            BackupExclusion.excludeMeetingAudio(meetingId: meetingId)
            try? modelContext.save()
            releaseAccess()
            return meetingId
        } catch {
            // 失败清理：删会议与半成品音频，不留空壳
            modelContext.delete(meeting)
            try? modelContext.save()
            MeetingAudioStore.deleteMeetingAudio(meetingId: meetingId)
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "导入失败：\(error.localizedDescription)")
            return nil
        }
    }

    func cancel() {
        releaseAccess()
        phase = .picking
    }

    private func releaseAccess() {
        if securityScoped, let url = sourceURL {
            url.stopAccessingSecurityScopedResource()
        }
        securityScoped = false
    }

    private func createdAt(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}

/// 导入弹层。
struct MeetingImportSheet: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var model = MeetingImporterModel()
    @State private var showPicker = false
    /// 导入成功：导航进会议页（调用方 `path.append`）。
    let onFinish: (UUID) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            header
            content
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.lg)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.phase == .importing)
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.audio],
            onCompletion: { result in
                if case .success(let url) = result { model.pick(url: url) }
            }
        )
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.recapCinnabar)
            Text("导入音频")
                .font(.recapTitle)
                .foregroundStyle(Color.recapInk)
            Text("录音笔、通话录音、语音消息——导入后自动转写并生成纪要。音频转码后保存在本机。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
                .multilineTextAlignment(.center)
                .lineSpacing(Leading.tight)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .picking:
            VStack(spacing: Spacing.md) {
                ForEach(supportedHints, id: \.self) { hint in
                    Label(hint, systemImage: "checkmark.circle")
                        .font(.recapBody)
                        .foregroundStyle(Color.recapTea)
                }
            }
        case .confirming:
            VStack(spacing: Spacing.md) {
                LabeledRow(label: "文件", value: model.fileName)
                if let d = model.durationText {
                    LabeledRow(label: "时长", value: d)
                }
                if RecapCredentialProvider.shared.isActiveCloud {
                    Text("云端转写将按音频时长消耗额度；导入后可在会议页重转或改用端侧模型。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                        .multilineTextAlignment(.center)
                }
            }
        case .importing:
            ProgressView("正在转码音频…")
                .font(.recapBody)
                .tint(Color.recapInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
        case .failed(let message):
            Text(message)
                .font(.recapBody)
                .foregroundStyle(Color.recapCinnabar)
                .multilineTextAlignment(.center)
                .padding(.vertical, Spacing.md)
        }
    }

    private var supportedHints: [String] {
        var hints = ["支持 m4a / wav / mp3 / aiff / caf 等常见格式", "自动转码为本机格式，转写与说话人分离照常可用"]
        if let d = model.durationText { hints.insert("时长 \(d)", at: 1) }
        return hints
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch model.phase {
        case .picking:
            primaryButton("选择文件") { showPicker = true }
            cancelButton
        case .confirming:
            primaryButton("导入并转写") {
                Task {
                    if let id = await model.confirm(modelContext: modelContext) {
                        onFinish(id)
                    }
                }
            }
            cancelButton
        case .importing:
            primaryButton("转码中…", enabled: false) {}
        case .failed:
            primaryButton("重新选择") { model.cancel(); showPicker = true }
            cancelButton
        }
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.recapTitleS)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(enabled ? Color.recapInk : Color.recapInk.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(RecapPressStyle())
        .disabled(!enabled)
    }

    private var cancelButton: some View {
        Button {
            model.cancel()
            onDismiss()
        } label: {
            Text("取消")
                .font(.recapBody)
                .foregroundStyle(Color.recapTea)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(RecapPressStyle())
    }

    private struct LabeledRow: View {
        let label: String
        let value: String
        var body: some View {
            HStack {
                Text(label)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                Spacer()
                Text(value)
                    .font(.recapBody)
                    .foregroundStyle(Color.recapInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
