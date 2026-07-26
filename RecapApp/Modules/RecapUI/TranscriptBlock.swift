import Foundation
import RecapModels

/// LIVE/逐字稿 UI 行模型（值类型；持久化仍用 TranscriptSegment）。
public struct TranscriptBlock: Identifiable, Hashable, Sendable {
    public let id: String
    public let speaker: Speaker
    public let timestamp: String
    public let raw: String
    public let polished: String
    public var isFinal: Bool
    /// ASR 原始起止秒；缺省时由 timestamp 字符串回退解析。
    public var startSeconds: Double?
    public var endSeconds: Double?

    public init(id: String = UUID().uuidString,
                speaker: Speaker,
                timestamp: String,
                raw: String,
                polished: String,
                isFinal: Bool,
                startSeconds: Double? = nil,
                endSeconds: Double? = nil) {
        self.id = id
        self.speaker = speaker
        self.timestamp = timestamp
        self.raw = raw
        self.polished = polished
        self.isFinal = isFinal
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public init(segment: TranscriptSegment, speakers: [Speaker], isFinal: Bool = true) {
        let speaker: Speaker = {
            if let sid = segment.speakerId,
               let match = speakers.first(where: { $0.id == sid }) {
                return match
            }
            // 未对齐说话人时不要统一叫「发言人」（易与 diarize 结果混淆）
            let fallbackName: String = {
                if let sid = segment.speakerId, sid.hasPrefix("spk") {
                    return "发言人"
                }
                return "转写"
            }()
            return Speaker(id: segment.speakerId ?? "?", name: fallbackName, colorIndex: 0)
        }()
        let total = Int(segment.startSeconds.rounded())
        self.init(
            id: segment.id.uuidString,
            speaker: speaker,
            timestamp: String(format: "%d:%02d", total / 60, total % 60),
            raw: segment.text,
            polished: segment.text,
            isFinal: isFinal,
            startSeconds: segment.startSeconds,
            endSeconds: segment.endSeconds
        )
    }
}

/// 降级演示内容：仅当 ASR / LLM 不可用时使用，不作为真实会议数据。
public enum DemoContent {
    public static let zhangming = Speaker(id: "s1", name: "张明", colorIndex: 0)
    public static let lihua = Speaker(id: "s2", name: "李华", colorIndex: 1)
    public static let lin = Speaker(id: "s3", name: "小林", colorIndex: 2)

    public static let script: [TranscriptBlock] = [
        .init(id: "t1", speaker: zhangming, timestamp: "14:31",
              raw: "那个我们这周把方案再过一下啊，预算这块我看了下",
              polished: "本周需复盘方案，核对预算", isFinal: true),
        .init(id: "t2", speaker: zhangming, timestamp: "14:31",
              raw: "我觉得移动端这块投入得加大",
              polished: "建议加大移动端投入", isFinal: true),
        .init(id: "t3", speaker: lihua, timestamp: "14:32",
              raw: "报价的话单台大概四百二吧，加上那个一年的服务费",
              polished: "单设备报价约 420 元，含一年服务", isFinal: true),
        .init(id: "t4", speaker: zhangming, timestamp: "14:33",
              raw: "那移动端这块我们这季度就提到总预算的百分之三十",
              polished: "本季移动端投入提至总预算 30%", isFinal: false),
        .init(id: "t5", speaker: lihua, timestamp: "14:34",
              raw: "行，那我周五之前把评审方案弄出来",
              polished: "李华本周五前出移动端评审方案", isFinal: false),
        .init(id: "t6", speaker: zhangming, timestamp: "14:35",
              raw: "客户的报价我再确认一下",
              polished: "张明跟进确认客户报价", isFinal: false),
    ]

    public static let fallbackTitle = "周会·产品评审"

    public static let fallbackSummary = MeetingSummary(
        tldr: "本次会议敲定移动端预算提至总预算 30%，采用单设备 420 元报价口径。李华负责本周五前出评审方案，张明跟进确认客户报价。iPad 是否纳入首批仍待结论。",
        topics: [
            MeetingTopic(
                title: "移动端预算",
                bullets: [
                    "投入提至总预算 30%",
                    "决议：采用「单设备 420 元」报价口径",
                ]
            ),
            MeetingTopic(
                title: "落地分工",
                bullets: [
                    "李华本周五前出评审方案",
                    "张明跟进客户报价确认",
                ]
            ),
        ],
        decisions: [
            "移动端投入提至总预算 30%",
            "采用「单设备 420 元」报价口径",
        ],
        openQuestions: [
            "是否纳入 iPad 端首批？—— 张明下周给结论",
        ]
    )
}
