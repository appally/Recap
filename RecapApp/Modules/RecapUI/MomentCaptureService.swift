@preconcurrency import AVFoundation
import UIKit

/// 会中拍照相机服务：独立 `AVCaptureSession`（仅照片输出），与 `AudioRecorder` 的音频管线
/// 完全隔离 —— 拍照不打断录音、不打断转写。硬件操作（配置 / 启停 / 拍照）序列化到
/// `sessionQueue`，UI 状态留在主线程（与 `AudioRecorder` 用 actor 隔离 `AVAudioEngine` 同思路）。
///
/// 并发：AVFoundation 类型尚未完成 `Sendable` 标注，故 `@preconcurrency import` 放宽；
/// `session` / `photoOutput` 标 `nonisolated(unsafe)`，因其本身线程安全且所有改动都经
/// `sessionQueue` 序列化。拍照经 `CaptureDelegate` + `CheckedContinuation<Data?>` 绕开
/// `UIImage` 非 `Sendable` 的跨 actor 难题（`Data` 可跨 actor 传递，调用方在主线程解码）。
///
/// 降级：模拟器 / 无相机设备 `isCameraAvailable == false`，调用方应据此禁用入口。
@MainActor
final class MomentCaptureService: NSObject, ObservableObject {

    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false

    /// 取景预览层（插入 overlay 的容器 UIView）。主线程持有。
    let previewLayer: AVCaptureVideoPreviewLayer

    nonisolated(unsafe) private let session: AVCaptureSession
    nonisolated(unsafe) private let photoOutput: AVCapturePhotoOutput
    private let sessionQueue = DispatchQueue(label: "com.recap.camera.session")
    /// 持有本次拍照 delegate 防释放（AVCapturePhotoCaptureDelegate 回调发生在 sessionQueue）。
    private var activeDelegate: CaptureDelegate?

    /// 设备是否支持拍照（模拟器 / 无相机返回 false）。
    nonisolated static var isCameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    /// 相机权限：已授权 true / 被拒 false / 未决定则弹系统请求。首次调用触发权限弹窗。
    func requestAccessIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    override init() {
        let session = AVCaptureSession()
        self.session = session
        self.photoOutput = AVCapturePhotoOutput()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer
        super.init()
    }

    /// 异步配置输入/输出；完成置 `isReady = true`。幂等。
    func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if self.session.inputs.isEmpty {
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video)
                if let device,
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
            }
            if self.session.outputs.isEmpty, self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.session.commitConfiguration()
            Task { @MainActor [weak self] in self?.isReady = true }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// 拍一张，返回原始图像数据（JPEG/HEIF，含 EXIF 朝向）。调用方在主线程 `UIImage(data:)`。
    /// 失败（未就绪 / 正在拍）返回 nil。
    func capture() async -> Data? {
        guard isReady, !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            // 强制 JPEG：使 fileDataRepresentation() 返回完整 JPEG 字节，与 .jpg 扩展名一致，
            // 落盘可直接写字节、无需 UIImage 重编码（主线程零编码开销）。JPEG 全设备支持。
            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.flashMode = .off
            // 系统快门音：MVP 依赖设备静音模式（方案 §5.3）；V2 在音频流打标记精修。
            let delegate = CaptureDelegate(continuation: continuation)
            activeDelegate = delegate
            sessionQueue.async { [photoOutput] in
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }
}

/// 一次性拍照 delegate holder：持有 continuation，回调里 resume。
/// `Data` 为 `Sendable`，可跨 actor 传递；`@unchecked Sendable` 因状态不可变且仅持 Sendable 续体。
private final class CaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let continuation: CheckedContinuation<Data?, Never>

    init(continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
        super.init()
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        if error != nil {
            continuation.resume(returning: nil)
            return
        }
        continuation.resume(returning: photo.fileDataRepresentation())
    }
}
