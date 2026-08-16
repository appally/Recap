import SwiftUI
import UniformTypeIdentifiers

// MARK: - ViewModel

@MainActor
final class BenchViewModel: ObservableObject {
    @Published var audioURL: URL?
    @Published var audioName: String = "(未选择音频)"
    @Published var selected: Set<AsrEngineKind> = [.speechAnalyzer, .volcSeedASR]  // 默认勾选无需 FluidAudio 的两个
    @Published var referenceText: String = ""
    @Published var referenceRTTM: String = ""
    @Published var records: [BenchRecord] = []
    @Published var isRunning = false
    @Published var status: String = "就绪"

    private let runner = BenchRunner()

    func toggle(_ k: AsrEngineKind) {
        if selected.contains(k) { selected.remove(k) } else { selected.insert(k) }
    }

    var canRun: Bool { !isRunning && audioURL != nil && !selected.isEmpty }

    func runAll() async {
        guard let url = audioURL else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            status = "读取并重采样音频为 16k mono…"
            let audio = try await AudioFileReader.loadResampled(url: url)
            let ref = referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       ? nil : referenceText
            let rttm = referenceRTTM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       ? nil : referenceRTTM

            for kind in AsrEngineKind.allCases where selected.contains(kind) {
                guard let engine = Self.makeEngine(kind) else {
                    status = "\(kind.rawValue) 在当前系统不可用，跳过"
                    continue
                }
                status = "评测 \(kind.rawValue)…"
                let record = await runner.run(
                    engine: engine,
                    audio: audio,
                    audioName: audioName,
                    reference: ref,
                    referenceRTTM: rttm)
                records.insert(record, at: 0)
            }
            status = "完成，共 \(records.count) 条记录"
        } catch {
            status = "音频读取失败：\(error.localizedDescription)"
        }
    }

    /// 按引擎种类构造。SpeechAnalyzer 需 iOS 26；不可用返回 nil。
    static func makeEngine(_ k: AsrEngineKind) -> AsrEngine? {
        switch k {
        case .fluidSenseVoice: return FluidAudioEngine(kind: .fluidSenseVoice)
        case .fluidParaformer: return FluidAudioEngine(kind: .fluidParaformer)
        case .fluidDiarizer:   return DiarizerEngine()
        case .speechAnalyzer:
            guard #available(iOS 26, *) else { return nil }
            return SpeechAnalyzerEngine()
        case .volcSeedASR:      return VolcASREngine()
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var vm = BenchViewModel()
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("音频") {
                    Button { showingPicker = true } label: {
                        Label(vm.audioName, systemImage: "waveform")
                    }
                    Text("重采样为 16k mono 后喂给所有引擎，统一输入。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("受测引擎") {
                    ForEach(AsrEngineKind.allCases) { kind in
                        Toggle(kind.rawValue, isOn: Binding(
                            get: { vm.selected.contains(kind) },
                            set: { _ in vm.toggle(kind) }))
                    }
                }

                Section("参考文本（可选，用于算 CER）") {
                    TextEditor(text: $vm.referenceText)
                        .frame(minHeight: 100)
                    Text("粘贴该音频的人工逐字稿。留空则只测 RTF/内存/发热，不算 CER。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("说话人时间轴 RTTM（可选，分离引擎算 DER）") {
                    TextEditor(text: $vm.referenceRTTM)
                        .frame(minHeight: 80)
                        .font(.system(size: 12, design: .monospaced))
                    Text("粘贴 RTTM 标注（SPEAKER file 1 start dur <NA> <NA> 说话人 <NA> <NA>）。留空则分离引擎只报说话人数/段数，不算 DER。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await vm.runAll() }
                    } label: {
                        if vm.isRunning { ProgressView().controlSize(.small) }
                        Text(vm.isRunning ? "评测中…" : "开始评测")
                    }
                    .disabled(!vm.canRun)
                    Text(vm.status).font(.caption).foregroundStyle(.secondary)
                }

                Section("结果（最新在上）") {
                    if vm.records.isEmpty {
                        Text("尚无记录").foregroundStyle(.secondary)
                    }
                    ForEach(vm.records) { ResultRow(record: $0) }
                }
            }
            .navigationTitle("RecapASRBench")
            .sheet(isPresented: $showingPicker) {
                DocumentPicker { url in
                    vm.audioURL = url
                    vm.audioName = url.lastPathComponent
                }
            }
        }
    }
}

struct ResultRow: View {
    let record: BenchRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.engine.rawValue).font(.headline)
                Spacer()
                if let err = record.error {
                    Text("⚠︎ 错误").foregroundStyle(.red).font(.caption)
                } else if let cer = record.cer {
                    Text(String(format: "CER %.1f%%", cer * 100))
                        .font(.headline).foregroundStyle(cerColor(cer))
                } else if let der = record.der {
                    Text(String(format: "DER %.1f%%", der * 100))
                        .font(.headline).foregroundStyle(cerColor(der))
                }
            }
            if let err = record.error {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                grid
            }
            Text(record.audioName).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var grid: some View {
        var items: [(String, String)] = [
            ("RTFx", String(format: "%.1f×", record.rtfx)),
            ("内存峰值", String(format: "%.0f MB", record.peakMemoryMB)),
            ("热档", record.peakThermal.label),
            ("掉电", record.batteryDeltaPct >= 0 ? String(format: "%.1f%%", record.batteryDeltaPct) : "—"),
        ]
        if let sc = record.speakerCount {
            // 分离引擎：显示说话人数 / 分离段（替代 ASR 的首字延迟 / 分块）。
            items.append(("说话人", "\(sc)"))
            items.append(("分离段", "\(record.segmentCount ?? 0)"))
            if let der = record.der {
                items.append(("DER", String(format: "%.1f%%", der * 100)))
            }
        } else {
            items.append(("首字延迟", record.firstTokenLatencyMs.map { String(format: "%.0f ms", $0) } ?? "—"))
            items.append(("分块", "\(record.chunkCount)"))
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                         alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { kv in
                VStack(alignment: .leading, spacing: 1) {
                    Text(kv.0).font(.caption2).foregroundStyle(.secondary)
                    Text(kv.1).font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func cerColor(_ cer: Double) -> Color {
        switch cer {
        case ..<0.05:  return .green
        case ..<0.12:  return .orange
        default:       return .red
        }
    }
}

// MARK: - 文件选择器

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
