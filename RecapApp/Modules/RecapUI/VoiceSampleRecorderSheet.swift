import SwiftUI
import RecapASR

/// 主动声纹录入：录一句 → 提取声纹 → 登记为「我」（proactive enrollment，不依赖会议分离）。
///
/// 编排 `AudioRecorder`（16k mono `[Float]`，内存攒块）→ `FluidDiarizer.extractEmbedding`
/// → `VoiceprintGallery.enrollAsMe`。须在外层已过 `VoiceprintConsent` 同意门后调用。
/// 模型首次需下载（`FluidDiarizer.prepare`），录满 `targetDuration` 自动停止提取。
@MainActor
final class VoiceSampleEnroller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparingModel
        case recording
        case extracting
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var elapsedSeconds: Double = 0

    /// 朗读提示句（约 6–8s）。
    static let promptSentence = "今天天气真不错，我们简单聊聊上周的项目进展，顺便过一下接下来的待办。"
    /// 录音目标时长（秒）。模型输入固定 10s/160k 采样，取 8s 清晰人声最稳。
    static let targetDuration: Double = 8.0

    private let recorder = AudioRecorder()
    private var samples: [Float] = []
    private var collectTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    /// 用户点「开始录音」：准备模型 → 录音 → 计时；到点自动停止并提取声纹。
    func start() async {
        guard phase == .idle || isFailed else { return }
        samples.removeAll(keepingCapacity: true)
        elapsedSeconds = 0
        audioLevel = 0
        phase = .preparingModel
        do {
            try await FluidDiarizer.shared.prepare()
        } catch {
            phase = .failed("声纹模型准备失败：\(error.localizedDescription)")
            return
        }
        await recorder.setOnAudioBands { [weak self] bands in
            Task { @MainActor in self?.audioLevel = bands.level }
        }
        let stream: AsyncStream<[Float]>
        do {
            stream = try await recorder.start()   // 默认 16k mono，内存攒块免落盘
        } catch {
            phase = .failed("无法开始录音：\(error.localizedDescription)")
            return
        }
        phase = .recording
        collectTask = Task { [weak self] in
            for await chunk in stream { self?.samples.append(contentsOf: chunk) }
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.elapsedSeconds = min(self.elapsedSeconds + 0.1, Self.targetDuration)
                if self.elapsedSeconds >= Self.targetDuration {
                    await self.stopAndEnroll()
                    return
                }
            }
        }
    }

    /// 手动提前停止并提取（与到点自动停止同路径）。
    func stopAndEnroll() async {
        guard case .recording = phase else { return }
        timerTask?.cancel(); timerTask = nil
        collectTask?.cancel(); collectTask = nil
        await recorder.stop()
        audioLevel = 0
        phase = .extracting
        guard !samples.isEmpty else {
            phase = .failed("未录到声音，请重试")
            return
        }
        do {
            let embedding = try await FluidDiarizer.shared.extractEmbedding(from: samples)
            VoiceprintGallery.shared.enrollAsMe(embedding: embedding)
            phase = .succeeded
        } catch {
            phase = .failed("声纹提取失败：\(error.localizedDescription)")
        }
    }

    /// 取消（关掉 sheet / 重置）。停录音、清状态。
    func cancel() {
        collectTask?.cancel(); collectTask = nil
        timerTask?.cancel(); timerTask = nil
        Task { await recorder.stop() }
        audioLevel = 0
        phase = .idle
    }
}

/// 主动声纹录入弹层：朗读 → 录满自动提取 → 成功/失败。
struct VoiceSampleRecorderSheet: View {
    @StateObject private var enroller = VoiceSampleEnroller()
    /// 关闭弹层（成功或取消后由调用方触发，调用方据此刷新画廊计数）。
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            header
            content
            if case .recording = enroller.phase { levelMeter }
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.lg)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(enroller.phase == .recording || enroller.phase == .extracting)
        .onDisappear { enroller.cancel() }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.recapCinnabar)
            Text("录入我的声音")
                .font(.recapTitle)
                .foregroundStyle(Color.recapInk)
            Text("录一句话，今后新会议将自动认出你。声纹仅保存在本机。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
                .multilineTextAlignment(.center)
                .lineSpacing(Leading.tight)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch enroller.phase {
        case .idle, .preparingModel, .recording:
            promptCard
        case .extracting:
            statusRow(icon: "waveform.badge.magicsign", text: "提取声纹中…", spin: true)
        case .succeeded:
            statusRow(icon: "checkmark.seal.fill", text: "已记住你的声音，今后新录音自动认出你。", spin: false, accent: true)
        case .failed(let msg):
            VStack(spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.recapCinnabar)
                Text(msg)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Leading.tight)
            }
            .padding(.vertical, Spacing.md)
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("请朗读这句话")
                .font(.recapCaption)
                .foregroundStyle(Color.recapTea)
            Text("「\(VoiceSampleEnroller.promptSentence)」")
                .font(.recapBody)
                .foregroundStyle(Color.recapInk)
                .lineSpacing(Leading.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if case .recording = enroller.phase {
                    Text(String(format: "%.0f / %.0f 秒", enroller.elapsedSeconds, VoiceSampleEnroller.targetDuration))
                        .font(.recapMono)
                        .foregroundStyle(Color.recapCinnabar)
                } else if case .preparingModel = enroller.phase {
                    Text("准备声纹模型…")
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea)
                } else {
                    Text("点下方按钮开始")
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea)
                }
                Spacer()
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.recapPaper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(Color.recapTea.opacity(0.12), lineWidth: 1))
    }

    private var levelMeter: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.recapCinnabar.opacity(0.25))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.recapCinnabar)
                        .frame(width: max(4, proxy.size.width * CGFloat(min(1, enroller.audioLevel))))
                }
                .frame(height: min(8, h))
        }
        .frame(height: 8)
    }

    @ViewBuilder
    private func statusRow(icon: String, text: String, spin: Bool, accent: Bool = false) -> some View {
        VStack(spacing: Spacing.sm) {
            if spin {
                ProgressView().tint(Color.recapCinnabar)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(accent ? Color.recapInk : Color.recapCinnabar)
            }
            Text(text)
                .font(.recapBody)
                .foregroundStyle(Color.recapInk)
                .multilineTextAlignment(.center)
                .lineSpacing(Leading.tight)
        }
        .padding(.vertical, Spacing.lg)
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch enroller.phase {
        case .idle:
            primaryButton("开始录音") { Task { await enroller.start() } }
            cancelButton
        case .preparingModel:
            primaryButton("准备模型…", enabled: false) {}
            cancelButton
        case .recording:
            primaryButton("停止并录入") { Task { await enroller.stopAndEnroll() } }
        case .extracting:
            primaryButton("提取中…", enabled: false) {}
        case .succeeded:
            primaryButton("完成") { onDismiss() }
        case .failed:
            primaryButton("重试") { Task { await enroller.start() } }
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
            enroller.cancel()
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
}
