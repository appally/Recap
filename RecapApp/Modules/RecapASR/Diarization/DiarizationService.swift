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
    ///
    /// `samples` 泛型（RandomAccessCollection）：允许零拷贝 mmap 视图（``MappedFloatSamples``）
    /// 直接流入 FluidAudio 的泛型管线，避免整场 `[Float]` 物化（2h 会议 ≈460MB 匿名堆 → jetsam）。
    /// 内部确需整场数组的实现（SpeakerKit 的 `audioArray:`）自行物化。
    func diarize<S: RandomAccessCollection & Sendable>(
        samples: S,
        numberOfSpeakers: Int?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerTimelineSegment]
    where S.Element == Float, S.Index == Int
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
        // mmap 零拷贝视图：不再整场物化 [Float]（2h 会议 ≈460MB、3h ≈691MB 匿名堆 → jetsam）。
        // FluidAudio 的 performCompleteDiarization 本就逐 chunk 拷进固定 chunkBuffer（泛型
        // RandomAccessCollection 入参），此前唯一逼出整场数组的是本层 [Float] 协议签名；
        // SpeakerKit 回退路径在实现内自行物化（audioArray: 要求）。
        let audioData = try MeetingAudioStore.loadMappedData(storedPath: audioPath)
        let samples = MappedFloatSamples(data: audioData)
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

        // 名字重放双层 key（plan 047 Wave A）：voiceprintId（跨跑稳定，优先）+ spk id（旧数据回退）。
        // spk 索引在重跑分离后按出现顺序重排，以其为 key 会把纠错名贴错人。
        // uniquingKeysWith 防御：多次重转/手改/迁移残留可能产生重复，取首个（保留最初命名）。
        let nameMap = Dictionary(preserveSpeakerNames.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // 跨会议重放：画廊里用户命名的身份（改名/标记我/合并保留名）跟随到本场——
        // SpeakerDetailSheet 承诺「改名或合并后，今后会议自动沿用」此前只兑现 id 未兑现名字：
        // 本场 preserve 列表在新会议为空，身份命中仍显「发言人N」。
        let voiceprintNameMap = Self.voiceprintNameMap(
            preserving: preserveSpeakerNames,
            galleryNames: VoiceprintGallery.shared.snapshot().map { ($0.id, $0.name) }
        )
        let speakers = SpeakerAligner.makeSpeakers(
            from: timeline,
            existingNames: nameMap,
            voiceprintNames: voiceprintNameMap
        )
        let labeled = SpeakerAligner.assignSpeakers(segments: segments, timeline: timeline)
        return Outcome(segments: labeled, speakers: speakers, timeline: timeline)
    }

    /// 声纹名字重放表（纯函数，RecapASRTests 回归锁定）：画廊用户命名 ∪ 本场纠错名，
    /// 本场优先（用户可能刚在本场改名）。**占位名不参与重放**——IdentityMatcher 自动建
    /// 条目叫「发言人 N」（带空格）、makeSpeakers 兜底叫「发言人N」，把假名钉死到每场
    /// 会议只会误导；画廊与占位名同时存在时以画廊真名兜底。
    public static func voiceprintNameMap(
        preserving speakers: [Speaker],
        galleryNames: [(voiceprintId: String, name: String)]
    ) -> [String: String] {
        func isPlaceholder(_ name: String) -> Bool {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return trimmed.range(of: #"^发言人\s*\d+$"#, options: .regularExpression) != nil
        }
        func entries(
            _ list: [(voiceprintId: String, name: String)]
        ) -> [String: String] {
            Dictionary(
                list.compactMap { entry -> (String, String)? in
                    guard !entry.voiceprintId.isEmpty, !isPlaceholder(entry.name) else { return nil }
                    return (entry.voiceprintId, entry.name)
                },
                uniquingKeysWith: { a, _ in a }
            )
        }
        let gallery = entries(galleryNames)
        let current = entries(
            speakers.compactMap { sp -> (voiceprintId: String, name: String)? in
                guard let vp = sp.voiceprintId, !vp.isEmpty else { return nil }
                return (vp, sp.name)
            }
        )
        // merging 闭包首参来自接收者(gallery)、次参来自入参(current)——本场名必须胜出
        return gallery.merging(current) { _, currentMeeting in currentMeeting }
    }
}
