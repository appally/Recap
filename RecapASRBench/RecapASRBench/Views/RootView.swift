import SwiftUI

/// 顶层 TabView：评测（选文件算 CER） + 实时（录音转写）。
struct RootView: View {
    var body: some View {
        TabView {
            ContentView()                       // 原评测台（选音频文件 → 三引擎对比 CER/RTF/内存/发热）
                .tabItem { Label("评测", systemImage: "chart.bar.xaxis") }

            if #available(iOS 26, *) {
                NavigationStack {
                    LiveTranscribeView()        // 实时录音转写（SpeechAnalyzer 流式）
                }
                .tabItem { Label("实时", systemImage: "mic.fill") }
            }

            NavigationStack {
                LLMSmokeTestView()              // Phase 1：MacPaw + DeepSeek V4 连通性实测
            }
            .tabItem { Label("LLM", systemImage: "sparkles") }
        }
    }
}
