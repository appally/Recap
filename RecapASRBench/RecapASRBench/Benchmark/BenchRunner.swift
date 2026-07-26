import Foundation

/// 跑一个引擎对一段音频的完整评测，产出 BenchRecord。
/// 内部用 BenchMonitor 采样内存/热/电量，并计时 RTFx。
actor BenchRunner {

    func run(engine: AsrEngine,
             audio: AudioFileReader.LoadedAudio,
             audioName: String,
             reference: String?,
             onPartial: (@Sendable (String) -> Void)? = nil) async -> BenchRecord {

        let monitor = BenchMonitor()
        await monitor.start()

        var transcript = ""
        var firstLat: Double?
        var chunks = 0
        var errMsg: String?
        let kind = engine.kind
        let started = Date()

        // 周期采样内存（200ms），与 transcribe 并发；转写结束后 cancel。
        let monitorRef = monitor
        let sampler = Task {
            while !Task.isCancelled {
                await monitorRef.sampleMemory()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        do {
            try await engine.prepare()
            let result = try await engine.transcribe(
                samples: audio.samples,
                sampleRate: audio.sampleRate,
                onPartial: onPartial)
            transcript = result.text
            firstLat = result.firstTokenLatencyMs
            chunks = result.chunkCount
        } catch {
            errMsg = error.localizedDescription
        }

        sampler.cancel()
        await engine.release()

        let elapsed = Date().timeIntervalSince(started)
        let (peakMem, peakThermal, batDelta) = await monitor.stop()
        let cer = reference.map {
            CERScorer.score(hypothesis: transcript, reference: $0).cer
        }

        return BenchRecord(
            engine: kind,
            audioName: audioName,
            transcript: transcript,
            cer: cer,
            audioSeconds: audio.durationSeconds,
            elapsedSeconds: elapsed,
            peakMemoryMB: peakMem,
            peakThermal: peakThermal,
            batteryDeltaPct: batDelta,
            firstTokenLatencyMs: firstLat,
            chunkCount: chunks,
            error: errMsg,
            timestamp: Date())
    }
}
