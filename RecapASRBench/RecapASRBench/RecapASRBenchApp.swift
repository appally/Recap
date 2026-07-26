import SwiftUI
import SwiftData

@main
struct RecapASRBenchApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: Meeting.self,
                TranscriptVersion.self,
                AIOutput.self,
                ActionItem.self,
                LLMProviderConfig.self
            )
        } catch {
            fatalError("无法初始化 ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
