import SwiftUI
import SwiftData
import UIKit
import RecapModels
import RecapPersistence
import RecapUI
import RecapASR

@main
struct RecapAppApp: App {
    let modelContainer: ModelContainer
    @State private var membership = MembershipStore.shared

    init() {
        do {
            modelContainer = try RecapDataContainer.make()
        } catch {
            fatalError("无法初始化 ModelContainer: \(error)")
        }
        // 端侧 FluidAudio 模型下载走国内镜像（HuggingFace 直连不稳）
        FluidAudioBootstrap.configureModelEndpoint()
        // 后台预拉 SpeechAnalyzer 中文资源，避免首次点录音卡在下载上
        if #available(iOS 26.0, *) {
            SpeechAnalyzerEngine.prefetchAssetsInBackground()
        }
        // 后台预拉 SpeakerKit 说话人模型（~10.7MB），避免首次会后说话人分离卡在下载上
        SpeakerKitDiarizer.prefetchInBackground()
        // 路径 C·POC：开启 FluidAudio 分离引擎时，后台预拉其模型（pyannote+WeSpeaker）。
        if ASRFeatureFlags.fluidDiarizerEnabled {
            FluidDiarizer.prefetchInBackground()
        }
        // 后台预热 mermaid WKWebView（共享进程池 + 触发 3.4MB JS parse），
        // 消除首图独立 spawn WebKit 进程组的 ~2.17s 冷启动。
        MermaidWebViewPreheater.prefetchInBackground()
    }

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environment(membership)
                .task {
                    await AppleCredentialChecker.reconcileIfNeeded()
                    await membership.start()
                    // Pro 会员(recapCloud):tier 同步后启动后台滚动续签阿里临时凭证
                    // (内部自判 recapCloud+Pro,否则 no-op);LLM/ASR 的 makeCurrent/prepare 读其缓存。
                    RecapCredentialProvider.shared.startBackgroundRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )) { _ in
                    // P0-①：系统内存告警 → 卸载 diarizer 模型（pyannote+WeSpeaker，20-40MB wired），
                    // 降低低内存机型(A14 iPad)被 jetsam 强杀概率。下次分离自动 reload（缓存命中 ~100ms）。
                    Task { await DiarizationService.activeDiarizer.unload() }
                    // 顺手丢弃 mermaid 预热 WebView（仅失热缓存，下次按需重建）。
                    MermaidWebViewPool.shared.evictOnMemoryPressure()
                }
        }
        .modelContainer(modelContainer)
    }
}
