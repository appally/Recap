import Foundation
import RecapModels

/// 说话人分离引擎抽象（会后批处理）。
///
/// 当前实现 `SpeakerKitDiarizer`（pyannote CoreML）。评估中的 AxiiDiarization
/// （Sortformer + Wespeaker；自带流式 + 跨录音身份）若 POC 通过，新增一个实现并在
/// `DiarizationService.diarizeMeeting` 默认参数处切换即可——SpeakerAligner / UI 均不动。
public protocol MeetingDiarizer: Sendable {
    /// 预下载/加载模型（可选预热；`diarize` 内部也会懒加载）。
    func prepare() async throws
    /// 对 16kHz mono Float PCM 跑完整文件分离，返回说话人时间轴。
    func diarize(
        samples: [Float],
        numberOfSpeakers: Int?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerTimelineSegment]
    /// 卸载模型。
    func unload() async
}

/// 会后说话人分离编排：读盘 → 分离引擎 → 对齐转写段 → 产出 speakers。
public enum DiarizationService {

    /// flag 门控选引擎：开启 FluidAudio 分离（路径 C·POC）则用 FluidDiarizer，否则回退 SpeakerKit。
    public static var activeDiarizer: any MeetingDiarizer {
        ASRFeatureFlags.fluidDiarizerEnabled ? FluidDiarizer.shared : SpeakerKitDiarizer.shared
    }

    public struct Outcome: Sendable {
        public let segments: [TranscriptSegment]
        public let speakers: [Speaker]
        public let timeline: [SpeakerTimelineSegment]

        public init(
            segments: [TranscriptSegment],
            speakers: [Speaker],
            timeline: [SpeakerTimelineSegment]
        ) {
            self.segments = segments
            self.speakers = speakers
            self.timeline = timeline
        }
    }

    /// 从本地 PCM + 现有转写段生成带 `speakerId` 的结果。
    public static func diarizeMeeting(
        audioPath: String,
        segments: [TranscriptSegment],
        numberOfSpeakers: Int? = nil,
        preserveSpeakerNames: [Speaker] = [],
        diarizer: any MeetingDiarizer = DiarizationService.activeDiarizer,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Outcome {
        guard MeetingAudioStore.fileExists(storedPath: audioPath) else {
            throw DiarizationError.missingAudio
        }
        guard !segments.isEmpty else {
            throw DiarizationError.emptyTranscript
        }
        let samples = try MeetingAudioStore.loadFloatSamples(storedPath: audioPath)
        guard !samples.isEmpty else {
            throw DiarizationError.emptyAudio
        }

        let timeline = try await diarizer.diarize(
            samples: samples,
            numberOfSpeakers: numberOfSpeakers,
            progress: progress
        )
        guard !timeline.isEmpty else {
            throw DiarizationError.engineFailed("未检测到说话人片段")
        }

        let nameMap = Dictionary(uniqueKeysWithValues: preserveSpeakerNames.map { ($0.id, $0.name) })
        let speakers = SpeakerAligner.makeSpeakers(from: timeline, existingNames: nameMap)
        let labeled = SpeakerAligner.assignSpeakers(segments: segments, timeline: timeline)
        return Outcome(segments: labeled, speakers: speakers, timeline: timeline)
    }
}
