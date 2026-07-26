import SwiftUI
import SwiftData
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
        // 后台预拉 SpeechAnalyzer 中文资源，避免首次点录音卡在下载上
        if #available(iOS 26.0, *) {
            SpeechAnalyzerEngine.prefetchAssetsInBackground()
        }
    }

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environment(membership)
                .task {
                    await AppleCredentialChecker.reconcileIfNeeded()
                    await membership.start()
                }
        }
        .modelContainer(modelContainer)
    }
}
