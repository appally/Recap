import SwiftUI
import UIKit
import AVFoundation
import RecapModels
import RecapASR

/// 会中拍照取景 Overlay：单击 / 连拍归入同一个 Moment，完成时把整组钉到 `anchorElapsed`
/// （打开取景瞬间的会议秒数）。MVP 仅拍照（无想法输入，V2）。相机是独立 `AVCaptureSession`，
/// 录音 / 转写不受影响。
struct MomentCaptureOverlay: View {
    let meeting: Meeting
    let anchorElapsed: Int
    let onComplete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var camera = MomentCaptureService()
    @State private var momentId = UUID()
    @State private var photoPaths: [String] = []
    @State private var thumbnails: [UIImage] = []
    @State private var accessGranted = false
    /// 快门闪光：capture 成功瞬间全屏白闪（相机标志反馈）。
    @State private var flashOpacity: Double = 0
    private var hasCamera: Bool { MomentCaptureService.isCameraAvailable }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                if hasCamera && accessGranted {
                    previewStage
                } else {
                    unavailableStage
                }
                Spacer(minLength: Spacing.xxl)
                controlDeck
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)

            // 快门闪光：覆盖全屏，不拦截点击。
            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .task { await boot() }
        .onDisappear { camera.stop() }
    }

    // MARK: - 启停

    private func boot() async {
        guard hasCamera else { return }
        let granted = await camera.requestAccessIfNeeded()
        accessGranted = granted
        guard granted else { return }
        camera.configure()
        camera.start()
    }

    // MARK: - 拍摄

    @MainActor
    private func shoot() async {
        Haptics.impact(.light)
        guard let data = await camera.capture() else { return }
        // 拍到才闪：快门白闪是「已记录」的标志反馈，先瞬时拉满再 ease-out 淡出。
        flashOpacity = 0.85
        withAnimation(.easeOut(duration: 0.2)) { flashOpacity = 0 }

        // 重活离线：直接落 fileDataRepresentation 字节（跳过 UIImage 解码 + JPEG 重编码）+
        // ImageIO 下采样出缩略图。主线程只等相对路径与缩略图数据回来，零编码开销。
        let meetingId = meeting.id
        let momentId = self.momentId
        let index = photoPaths.count
        let outcome: (String, Data?)? = await Task.detached(priority: .utility) {
            guard let rel = try? MeetingMediaStore.saveData(
                data, meetingId: meetingId, momentId: momentId, index: index) else { return nil }
            return (rel, MeetingMediaStore.makeThumbnailData(from: data))
        }.value
        guard let (rel, thumbData) = outcome else {
            // 静默失败（不阻断后续拍摄，对齐 LocationCaptureService 风格）
            return
        }
        // 缩略图退化：ImageIO 极少失败，失败时回退到解码原图（仅多一次主线程解码）。
        let thumb = thumbData.flatMap(UIImage.init(data:)) ?? UIImage(data: data)
        withAnimation(.recapSoft) {
            photoPaths.append(rel)
            if let thumb { thumbnails.append(thumb) }
        }
    }

    /// 关闭：拍了至少一张就落库为 Moment 并钉到锚点；一张没拍则什么都不产生。
    private func finish() {
        camera.stop()
        if !photoPaths.isEmpty {
            let moment = Moment(
                startSeconds: Double(anchorElapsed),
                kind: .photo,
                noteText: nil,
                photoRelativePaths: photoPaths,
                meeting: meeting
            )
            modelContext.insert(moment)
            try? modelContext.save()
            // V2：异步回填照片文字（白板 / PPT），供图库展示与纪要 prompt 注入。
            MomentOCRService.shared.extractIfAbsent(for: moment)
            Haptics.notify(.success)
        }
        onComplete()
    }

    // MARK: - 组成

    private var topBar: some View {
        HStack {
            Text("记录此刻")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                finish()
            } label: {
                Image(systemName: RecapSymbol.close)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("完成拍照")
        }
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }

    private var previewStage: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreviewView(previewLayer: camera.previewLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

            if !thumbnails.isEmpty {
                thumbnailStack
                    .padding(Spacing.md)
            }
        }
    }

    private var unavailableStage: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: RecapSymbol.camera)
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.4))
            Text(hasCamera ? "请允许相机权限" : "相机不可用")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text("拍照记录需在真机使用；模拟器可查看已有时刻卡片")
                .font(.recapMeta)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thumbnailStack: some View {
        HStack(spacing: -14) {
            ForEach(Array(thumbnails.suffix(3).enumerated()), id: \.offset) { _, img in
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white, lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 3)
            }
            Text("\(thumbnails.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.recapCeladon, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
        .transition(.scale.combined(with: .opacity))
    }

    private var controlDeck: some View {
        HStack(spacing: Spacing.xxl) {
            VStack(spacing: 2) {
                Text("\(photoPaths.count)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(photoPaths.isEmpty ? .white.opacity(0.35) : Color.recapCeladon)
                Text("本刻")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: 64)
            .accessibilityLabel("已拍 \(photoPaths.count) 张")

            Spacer()

            shutterButton

            Spacer()

            Button {
                finish()
            } label: {
                VStack(spacing: 2) {
                    Text(photoPaths.isEmpty ? "完成" : "钉到")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(photoPaths.isEmpty ? .white.opacity(0.5) : .white)
                    if !photoPaths.isEmpty {
                        Text(timeText(anchorElapsed))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.recapCeladon)
                    }
                }
                .frame(width: 64)
            }
            .disabled(photoPaths.isEmpty)
            .accessibilityLabel(photoPaths.isEmpty ? "完成" : "把 \(photoPaths.count) 张照片钉到 \(timeText(anchorElapsed))")
        }
    }

    private var shutterButton: some View {
        Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(camera.isCapturing ? Color.white.opacity(0.6) : Color.white)
                    .frame(width: 60, height: 60)
                    .scaleEffect(camera.isCapturing ? 0.86 : 1)
            }
            // 快门：比 recapSoft 更快、略带 overshoot，像按下机械快门的弹回。
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: camera.isCapturing)
        }
        .disabled(camera.isCapturing)
        .accessibilityLabel("拍照")
    }

    private func timeText(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - 取景预览容器

/// 把 `AVCaptureVideoPreviewLayer` 包进 SwiftUI：layer 跟随容器尺寸。
private struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewContainer {
        let view = PreviewContainer()
        view.backgroundColor = .black
        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        previewLayer.frame = uiView.bounds
    }

    final class PreviewContainer: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            (layer.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = bounds
        }
    }
}
