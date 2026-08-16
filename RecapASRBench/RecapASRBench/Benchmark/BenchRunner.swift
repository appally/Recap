import Foundation

/// 跑一个引擎对一段音频的完整评测，产出 BenchRecord。
/// 内部用 BenchMonitor 采样内存/热/电量，并计时 RTFx。
actor BenchRunner {

    func run(engine: AsrEngine,
             audio: AudioFileReader.LoadedAudio,
             audioName: String,
             reference: String?,
             referenceRTTM: String? = nil,
             onPartial: (@Sendable (String) -> Void)? = nil) async -> BenchRecord {

        let monitor = BenchMonitor()
        await monitor.start()

        var transcript = ""
        var firstLat: Double?
        var chunks = 0
        var errMsg: String?
        var speakerCount: Int?
        var segCount: Int?
        var der: Double?
        let kind = engine.kind
        let started = Date()

        // 周期采样内存（200ms），与推理并发；结束后 cancel。
        let monitorRef = monitor
        let sampler = Task {
            while !Task.isCancelled {
                await monitorRef.sampleMemory()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        do {
            try await engine.prepare()
            if let de = engine as? any DiarizerBench {
                // 分离引擎：跑 diarize，产出说话人数 / 段数（无文本，不算 CER）；
                // 提供 RTTM 参考时算 DER（052 P1-2：SpeakerKit vs FluidDiarizer 对比度量）。
                let res = try await de.diarize(samples: audio.samples, sampleRate: audio.sampleRate)
                speakerCount = res.speakerCount
                segCount = res.segments.count
                let rttm = referenceRTTM?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !rttm.isEmpty {
                    let refSegs = DERScorer.parseRTTM(rttm)
                    let hypSegs = res.segments.map {
                        DERScorer.Segment(speaker: $0.speakerId,
                                          start: $0.startSeconds,
                                          end: $0.endSeconds)
                    }
                    der = DERScorer.score(hypothesis: hypSegs, reference: refSegs)?.der
                }
            } else {
                let result = try await engine.transcribe(
                    samples: audio.samples,
                    sampleRate: audio.sampleRate,
                    onPartial: onPartial)
                transcript = result.text
                firstLat = result.firstTokenLatencyMs
                chunks = result.chunkCount
            }
        } catch {
            errMsg = error.localizedDescription
        }

        sampler.cancel()
        await engine.release()

        let elapsed = Date().timeIntervalSince(started)
        let (peakMem, peakThermal, batDelta) = await monitor.stop()
        // CER 仅对 ASR（有 transcript）且提供参考文本时算；分离引擎 transcript 为空 → nil。
        let cer: Double? = (reference != nil && !transcript.isEmpty)
            ? CERScorer.score(hypothesis: transcript, reference: reference!).cer
            : nil

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
            timestamp: Date(),
            speakerCount: speakerCount,
            segmentCount: segCount,
            der: der)
    }
}
