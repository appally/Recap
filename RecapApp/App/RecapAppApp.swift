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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            modelContainer = try RecapDataContainer.make()
        } catch {
            // make() 自身已有“备份降级到内存库”兜底；走到这里说明降级也失败（极罕见，
            // 如 schema 在该系统上无法构建内存库、或播种预置数据抛错）。
            // 用一个不播种的空内存容器兜底，避免启动 fatalError 直接变砖——
            // 用户至少能看到可运行的空 App 并在设置里反馈，而非白屏闪退。
            let bare = ModelConfiguration(schema: RecapDataContainer.schema, isStoredInMemoryOnly: true)
            do {
                modelContainer = try ModelContainer(
                    for: RecapDataContainer.schema, configurations: [bare])
            } catch {
                // 连空内存库都建不出来 = SwiftData 在本机完全不可用，确属不可恢复态。
                fatalError("ModelContainer 不可恢复: \(error)")
            }
        }
        // 仅配置端侧模型下载镜像 URL（HuggingFace 直连不稳）——纯 URL 配置，不触发下载/编译。
        FluidAudioBootstrap.configureModelEndpoint()
        // 重资产预热已全部移出 init() 冷启动路径：
        //   • SpeechAnalyzer 中文资源 / SpeakerKit 模型下载
        //   • FluidDiarizer ANE 特化编译（~16-24s，一次性）
        //   • mermaid WKWebView 进程组孵化（~6.7s × 3 辅助进程）
        // 改为首帧渲染后错峰启动（见 `Warmup.startPostFrame`），避免上述并发争 CPU/ANE/内存
        // 致首屏卡顿 + WebContent unresponsive（详见 2026-08-02 首启卡顿排查）。
    }

    var body: some Scene {
        WindowGroup {
            // plan 064：人物升为一等入口（TabView）。FAB/搜索/设置仍属「记录」tab——
            // MeetingListView 自带 NavigationStack + 状态，包 TabView 无需其内部改动。
            TabView {
                MeetingListView()
                    .tabItem { Label("记录", systemImage: "waveform.circle.fill") }
                PeopleView()
                    .tabItem { Label("人物", systemImage: "person.2.fill") }
            }
            .environment(membership)
            .task {
                // 首帧渲染后启动错峰预热（fire-and-forget，后台 utility）：ASR 资源/SpeakerKit
                // 下载 → 间隔 → FluidDiarizer 编译。详见 `Warmup.startPostFrame`。
                Warmup.startPostFrame()
                await AppleCredentialChecker.reconcileIfNeeded()
                await membership.start()
                // Pro 会员(recapCloud):tier 同步后启动后台滚动续签阿里临时凭证
                // (内部自判 recapCloud+Pro,否则 no-op);LLM/ASR 的 makeCurrent/prepare 读其缓存。
                RecapCredentialProvider.shared.startBackgroundRefresh()
            }
            .onChange(of: scenePhase) { _, phase in
                // 回前台即对账权益：App 常驻多日不杀时，订阅过期/退款不会即时回收
                // （云端有网关验签兜底，但本地 UI 会一直显示过期的 Pro）。启动/购买/恢复/
                // Transaction.updates 之外的这块盲区由 active 对账补上。
                guard phase == .active else { return }
                Task { await membership.refreshEntitlements() }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )) { _ in
                // P0-①：系统内存告警 → 卸载 diarizer 模型（pyannote+WeSpeaker，20-40MB wired），
                // 降低低内存机型(A14 iPad)被 jetsam 强杀概率。下次分离自动 reload（缓存命中 ~100ms）。
                Task {
                    await DiarizationService.activeDiarizer.unload()
                    // CAM++ embedder 同批卸载（CoreML 常驻；diarizer 三件套外的漏网项）
                    await CampPlusEmbedderProvider.shared.unload()
                }
                // 顺手丢弃 mermaid 预热 WebView（仅失热缓存，下次按需重建）。
                MermaidWebViewPool.shared.evictOnMemoryPressure()
            }
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - 启动期错峰预热

/// 把重资产预热从 `init()` 冷启动路径移到「首帧渲染后」，串行错峰避免争资源。
///
/// 背景（2026-08-02 首启卡顿排查）：原先 `init()` 同时点火四路重负载——
///   ① CoreML 编译 FluidDiarizer（wespeaker 24s + pyannote 2s，饱和 ANE/CPU）
///   ② WebKit 进程组孵化（GPU/Networking/WebContent 各 ~6.7s，WebContent 一度 unresponsive）
///   ③ SpeechAnalyzer 中文资源下载　④ SpeakerKit 模型下载（~10.7MB）
/// 四者并发争抢 6 核 / 7.5GB，首屏掉帧、`mach_vm_allocate` 失败、手势超时。
///
/// 现策略：
///   • 轻量下载（③④）首帧后即起——录音前需要，下载无编译、争用小。
///   • FluidDiarizer 编译（①）延后 2s 再起、放最后：它会饱和 ANE，与 live ASR 推理争用，
///     故不挂在「录音开始」（那正是端侧 ASR 跑 ANE 的时刻），而是赶在用户录音前尽量跑完。
///   • mermaid WebView（②）改为懒触发：不再冷启预热，首图由 `MermaidDiagramView`
///     按需创建 WebView（首图付一次进程孵化，远好于拖垮整个冷启动）。
private enum Warmup {
    static func startPostFrame() {
        Task.detached(priority: .utility) {
            // ① 录音前需要的轻量资产（下载，无端侧编译）
            if #available(iOS 26.0, *) {
                SpeechAnalyzerEngine.prefetchAssetsInBackground()
            }
            SpeakerKitDiarizer.prefetchInBackground()

            // ② 让首帧完全落地、轻量下载先行，再启动重编译
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // ③ FluidDiarizer ANE 特化编译（~16-24s，一次性；缓存命中后续启动 ~100ms 重载）。
            //   最重且会饱和 ANE，放最后；分离只在会后 REVIEW 触发，整个录音期间足够编译完成。
            if ASRFeatureFlags.fluidDiarizerEnabled {
                FluidDiarizer.prefetchInBackground()
            }
        }
    }
}
