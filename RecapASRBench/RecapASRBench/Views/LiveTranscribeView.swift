import SwiftUI
import AVFoundation
import Speech
import FluidAudio

// ─────────────────────────────────────────────────────────────────────────────
// 实时录音转写（三引擎可切换）：
//   • SpeechAnalyzer：原生流式（bestAvailableAudioFormat + prepareToAnalyze），端侧低延迟
//   • FluidAudio SenseVoice：批处理，攒 6s 一段伪流式（端侧，免费/隐私）
//   • 火山 Seed-ASR：WebSocket 流式（云端，最准），复用 VolcFrame/VolcConfig 帧编解码
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 26.0, *)
@MainActor
final class LiveTranscriber: ObservableObject {

    enum Engine: String, CaseIterable, Identifiable {
        case speech = "SpeechAnalyzer（端侧）"
        case fluid  = "FluidAudio（端侧）"
        case volc   = "火山（云端）"
        var id: String { rawValue }
    }

    @Published var engine: Engine = .speech
    @Published var isRecording = false
    @Published var finalText = ""
    @Published var liveText = ""
    @Published var elapsed: TimeInterval = 0
    @Published var error: String?
    @Published var status = "就绪"

    private let recorder = AudioRecorder()
    private var tasks: [Task<Void, Never>] = []
    private var isStarting = false   // 防重入：start 是 async，避免并发/快速点击重复启动
    private var lastToggle = Date.distantPast   // toggle 防抖：避免快速双击 start→stop
    private var timer: Timer?
    private var startTime: Date?

    private var speechAnalyzer: SpeechAnalyzer?
    private var fluidManager: SenseVoiceManager?
    // 火山方舟（Ark）：用 doubao-seed-2.0 多模态的 SpeechToText（chat completions + input_audio）
    // ⚠️ 需在方舟控制台开通 doubao-seed-2-0-mini 模型，否则报 ModelNotOpen
    private let arkKey = "ark-b9ff047b-7c30-49c4-9d43-55630c42af79-5c68c"
    private let arkModel = "doubao-seed-2-0-mini-260428"   // 也可用 doubao-seed-2-0-lite-260428
    private let arkURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!

    // 火山大模型流式 ASR（官方 SpeechEngineToB SDK，旧版鉴权 App ID + Access Token）
    private let volcAppId = "3694046975"
    private let volcAccessToken = "0r55raj_ZdlYKZcN_dKgCwHGFbgLOmmQ"
    private let volcResource = "volc.seedasr.sauc.duration"
    private let volcAddress = "wss://openspeech.bytedance.com"
    private let volcURI = "/api/v3/sauc/bigmodel_async"
    private var volcEngine: VolcSpeechEngine?

    func toggle() async {
        let now = Date()
        if now.timeIntervalSince(lastToggle) < 1.5 { print("LT: toggle 防抖忽略（<1.5s）"); return }
        lastToggle = now
        isRecording ? await stop() : await start()
    }

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        finalText = ""; liveText = ""; error = nil; elapsed = 0
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startTime else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
        do {
            switch engine {
            case .speech: try await startSpeech()
            case .fluid:  try await startFluid()
            case .volc:   try await startVolc()
            }
            isRecording = true
            status = "录音中…"
        } catch {
            self.error = error.localizedDescription
            timer?.invalidate(); timer = nil
        }
    }

    // MARK: - SpeechAnalyzer（端侧流式）
    private func startSpeech() async throws {
        status = "① 检查可用性…"
        print("SA: isAvailable check")
        guard SpeechTranscriber.isAvailable else { print("SA: ❌ not available"); throw LiveError.unavailable }
        print("SA: isAvailable OK")

        let locale = Locale(identifier: "zh-CN")
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        status = "② 分配中文模型…"
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        print("SA: assetStatus=\(assetStatus)")
        if assetStatus != .installed {
            if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                print("SA: downloading...")
                try await req.downloadAndInstall()
                print("SA: download done")
            } else { print("SA: no install request") }
        }
        print("SA: reserve...")
        try await AssetInventory.reserve(locale: locale)
        print("SA: reserve done")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        speechAnalyzer = analyzer

        status = "③ 准备分析器…"
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let rate = analysisFormat?.sampleRate ?? 16000
        print("SA: format rate=\(rate) fmt=\(analysisFormat == nil ? "nil" : "ok")")
        print("SA: prepareToAnalyze...")
        do { try await analyzer.prepareToAnalyze(in: analysisFormat); print("SA: prepare done") }
        catch { print("SA: prepare error \(error)") }

        status = "④ 启动录音…"
        print("SA: recorder.start rate=\(rate)")
        let samples = try await recorder.start(targetSampleRate: rate)
        print("SA: recorder started")
        let (inputStream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        tasks.append(Task {
            var n = 0
            for await s in samples {
                cont.yield(AnalyzerInput(buffer: Self.makeBuffer(s, sampleRate: rate)))
                n += 1
                if n == 1 { print("SA: first sample fed") }
            }
            print("SA: samples ended, chunks=\(n)")
            cont.finish()
        })

        status = "⑤ 录音中，请说话…"
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            var seen: [(Double, String)] = []
            let results = transcriber.results
            var gotFirst = false
            print("SA: iterating results")
            do {
                for try await r in results {
                    if !gotFirst { gotFirst = true; self.status = "✅ 已收到结果"; print("SA: FIRST RESULT") }
                    let text = String(r.text.characters)
                    let k = r.range.start.seconds
                    if let i = seen.firstIndex(where: { $0.0 == k }) { seen[i] = (k, text) }
                    else { seen.append((k, text)) }
                    seen.sort { $0.0 < $1.0 }
                    if seen.count > 1 {
                        self.finalText = seen.dropLast().map { $0.1 }.joined()
                        self.liveText = seen.last?.1 ?? ""
                    } else {
                        self.finalText = ""
                        self.liveText = seen.first?.1 ?? ""
                    }
                }
                self.finalText += self.liveText
                self.liveText = ""
                print("SA: results ended")
            } catch {
                self.error = "结果流错误：\(error.localizedDescription)"
                print("SA: results error \(error)")
            }
        })

        tasks.append(Task { [weak analyzer] in
            print("SA: analyzer.start")
            do { try await analyzer?.start(inputSequence: inputStream); print("SA: analyzer.start returned") }
            catch { await MainActor.run { self.error = "analyzer：\(error.localizedDescription)" }; print("SA: analyzer.start error \(error)") }
        })
    }

    // MARK: - FluidAudio SenseVoice（端侧，伪流式：攒 6s 一段批处理）
    private func startFluid() async throws {
        status = "加载模型…"
        let m = try await SenseVoiceManager.load(precision: .fp16)   // int8 在部分机型 ANE 失败，用 fp16
        fluidManager = m
        status = "录音中…"
        let samples = try await recorder.start(targetSampleRate: 16000)
        let chunkSize = Int(16000 * 6.0)   // 6s/段（太短易截断语义，太长延迟大）
        tasks.append(Task { [weak self, weak m] in
            var buf: [Float] = []
            for await s in samples {
                buf.append(contentsOf: s)
                while buf.count >= chunkSize {
                    let chunk = Array(buf.prefix(chunkSize))
                    buf.removeFirst(chunkSize)
                    if let txt = try? await m?.transcribe(audio: chunk), !txt.isEmpty {
                        await MainActor.run { self?.finalText += txt }
                    }
                }
                await MainActor.run { self?.liveText = "识别中…（缓冲 \(buf.count / 16000)s）" }
            }
            if !buf.isEmpty, let txt = try? await m?.transcribe(audio: buf), !txt.isEmpty {
                await MainActor.run { self?.finalText += txt }
            }
            await MainActor.run { self?.liveText = "" }
        })
    }

    // MARK: - 火山大模型流式 ASR（官方 SpeechEngineToB SDK，实时流式 + SDK 内置录音 AEC）
    private func startVolc() async throws {
        guard !volcAppId.isEmpty else { throw LiveError.noVolcCredentials }
        let e = VolcSpeechEngine()
        e.onResult = { [weak self] txt, _ in
            Task { @MainActor in if !txt.isEmpty { self?.finalText = txt; self?.liveText = "" } }
        }
        e.onError = { [weak self] err in Task { @MainActor in self?.error = "火山SDK: \(err)" } }
        e.onState = { [weak self] s in Task { @MainActor in self?.status = s } }
        e.setup(appId: volcAppId, token: volcAccessToken, resource: volcResource, address: volcAddress, uri: volcURI)
        volcEngine = e
        e.start()
        status = "录音中…（火山SDK，说话即出字）"
    }

    // MARK: - 停止
    func stop() async {
        timer?.invalidate(); timer = nil
        await recorder.stop()                                        // → 各 samples 流 finish → 引擎收尾
        if let a = speechAnalyzer { try? await a.finalizeAndFinishThroughEndOfInput() }
        for t in tasks { t.cancel() }
        tasks.removeAll()
        volcEngine?.stop(); volcEngine?.destroy(); volcEngine = nil
        speechAnalyzer = nil; fluidManager = nil
        isRecording = false
        status = "已停止"
    }

    // MARK: - 工具
    static func makeBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        let p = buf.floatChannelData![0]
        for i in 0..<samples.count { p[i] = samples[i] }
        return buf
    }
    static func toInt16Data(_ samples: [Float]) -> Data {
        var int16 = samples.map { Int16(max(-32768, min(32767, Double($0) * 32767))) }
        return Data(bytes: &int16, count: int16.count * 2)
    }

    /// 方舟 chat completions 音频转写（doubao-seed-2.0 多模态 SpeechToText）
    static func transcribeArk(samples: [Float], sampleRate: Double, key: String, model: String, url: URL) async throws -> String {
        let wavB64 = Self.wavBase64(samples: samples, sampleRate: sampleRate)
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": [
                ["type": "input_audio", "input_audio": ["data": wavB64, "format": "wav"]],
                ["type": "text", "text": "请逐字转写这段语音为文字，只输出转写结果"]
            ]]]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Ark", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "方舟 \(http.statusCode): \(msg.prefix(200))"])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return "" }
        if let s = message["content"] as? String { return s }
        if let arr = message["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    /// [Float] → wav(pcm_s16le) → base64
    static func wavBase64(samples: [Float], sampleRate: Double) -> String {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-32768, min(32767, Double(s) * 32767)))
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func appendU32(_ v: UInt32) { var b = v.littleEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { var b = v.littleEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); appendU32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); appendU32(16); appendU16(1); appendU16(1)
        appendU32(UInt32(sampleRate)); appendU32(UInt32(sampleRate) * 2); appendU16(2); appendU16(16)
        d.append("data".data(using: .ascii)!); appendU32(UInt32(pcm.count))
        d.append(pcm)
        return d.base64EncodedString()
    }
}

enum LiveError: Error, LocalizedError {
    case unavailable, noChineseAsset, noVolcCredentials
    var errorDescription: String? {
        switch self {
        case .unavailable:        return "SpeechAnalyzer 不可用（需 iOS 26 + Apple Intelligence 机型，如 iPhone 15 Pro+）"
        case .noChineseAsset:     return "设备未安装中文语音资产：系统设置 → 通用 → 键盘 → 听写语言 下载中文，或确认联网"
        case .noVolcCredentials:  return "未填火山凭证（LiveTranscribeView.swift 顶部 volcAppKey/volcAccessKey）"
        }
    }
}

// MARK: - UI

@available(iOS 26.0, *)
struct LiveTranscribeView: View {
    @StateObject private var vm = LiveTranscriber()

    var body: some View {
        VStack(spacing: 14) {
            Picker("引擎", selection: $vm.engine) {
                ForEach(LiveTranscriber.Engine.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isRecording)
            .padding(.horizontal)

            HStack {
                Text(timeString(vm.elapsed)).monospacedDigit().font(.headline)
                Spacer()
                Text(vm.status).foregroundStyle(.secondary).font(.subheadline)
            }
            .padding(.horizontal)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.finalText.isEmpty ? "" : vm.finalText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(vm.liveText).font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if vm.finalText.isEmpty && vm.liveText.isEmpty {
                        Text(vm.isRecording ? "请开始说话…" : "选引擎 → 点下方按钮开始")
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            if let err = vm.error {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal).multilineTextAlignment(.center)
            }

            Button { Task { await vm.toggle() } } label: {
                Circle()
                    .fill(vm.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 80, height: 80)
                    .overlay(Image(systemName: vm.isRecording ? "stop.fill" : "mic.fill")
                        .foregroundStyle(.white).font(.title))
            }
            Text(vm.isRecording ? "点击停止" : "点击开始").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 10)
        }
        .padding(.top)
        .navigationTitle("实时录音转写")
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t) % 60, m = (Int(t) / 60) % 60, h = Int(t) / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
