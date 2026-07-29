import Foundation
import SwiftData

/// 转写稿版本类型。
public enum TranscriptKind: String, Codable, Sendable {
    case raw        // 原始逐字稿
    case polished   // LLM 纠错润色后
}

/// 一次会议（录音 -> 转写 -> 理解 -> 行动 的聚合根）。
@Model
public final class Meeting {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var audioPath: String?
    /// 会话三态（LIVE / PROCESS / REVIEW），驱动首页列表与纪要界面。
    public var phase: MeetingPhase

    /// 原始转写分段，JSON blob 存储（SwiftData 存自定义结构数组的最稳做法）。
    public var segmentsData: Data
    /// 说话人列表，JSON blob。
    public var speakersData: Data

    /// 会议地点快照（开录时自动定位 + 反地理编码）；可空，无定位时行为与旧版一致。
    public var locationData: Data?

    /// LLM 润色后的转写分段（保段对应：与 segments 同 id/时间戳，仅 text 被润色）；nil = 未润色。
    public var polishedSegmentsData: Data?
    /// 润色所用模型 id（如 deepSeekFlash）；nil = 未润色。
    public var polishedModelId: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptVersion.meeting)
    public var transcriptVersions: [TranscriptVersion] = []

    @Relationship(deleteRule: .cascade, inverse: \AIOutput.meeting)
    public var outputs: [AIOutput] = []

    @Relationship(deleteRule: .cascade, inverse: \ActionItem.meeting)
    public var actionItems: [ActionItem] = []

    /// 会中拍下的「时刻」：照片锚定到录音秒，回看时与转写分段按 startSeconds 合并。
    @Relationship(deleteRule: .cascade, inverse: \Moment.meeting)
    public var moments: [Moment] = []

    /// 会中 / 会后的手写笔记（Apple Pencil）；识别文字注入纪要上下文。
    @Relationship(deleteRule: .cascade, inverse: \HandwritingNote.meeting)
    public var handwritingNotes: [HandwritingNote] = []

    /// 会前底稿（议程 / 上场遗留）；可空，无底稿时行为与旧版一致。
    @Relationship(deleteRule: .cascade, inverse: \MeetingBrief.meeting)
    public var brief: MeetingBrief?

    /// Ask 会话（可恢复 / 可审计）；删除会议时级联清空。
    @Relationship(deleteRule: .cascade, inverse: \ChatSession.meeting)
    public var chatSessions: [ChatSession] = []

    /// 深度调研等长任务。
    @Relationship(deleteRule: .cascade, inverse: \AgentTask.meeting)
    public var agentTasks: [AgentTask] = []

    /// 避免每次读属性都 JSON 解码，进纪要页时卡顿的主因之一。
    @Transient private var segmentsCache: [TranscriptSegment]?
    @Transient private var speakersCache: [Speaker]?

    public init(id: UUID = UUID(),
                title: String,
                startedAt: Date = .now,
                durationSeconds: Double = 0,
                audioPath: String? = nil,
                phase: MeetingPhase = .review,
                segments: [TranscriptSegment] = [],
                speakers: [Speaker] = []) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.audioPath = audioPath
        self.phase = phase
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.speakersData = (try? JSONEncoder().encode(speakers)) ?? Data()
        self.segmentsCache = segments
        self.speakersCache = speakers
    }

    /// 取或创建本场底稿（调用方负责 context.insert / save）。
    @discardableResult
    public func ensureBrief() -> MeetingBrief {
        if let brief { return brief }
        let created = MeetingBrief(meeting: self)
        brief = created
        return created
    }

    /// 注入纪要用的稳定摘要；无底稿或空底稿返回 nil。
    public var briefPromptSummary: String? {
        guard let brief, !brief.summaryForPrompt.isEmpty else { return nil }
        return brief.summaryForPrompt
    }

    /// 注入纪要 prompt 的「用户标记时刻」摘要（时间戳 + 想法 + 照片 OCR）；无则 nil。
    /// 让 AI 生成的纪要/待办优先覆盖用户在会中特意拍下/标记的内容。
    public var momentsPromptSummary: String? {
        guard !moments.isEmpty else { return nil }
        let lines = moments.sorted { $0.startSeconds < $1.startSeconds }.map { m -> String in
            var parts = ["[\(m.sourceTime)]"]
            let note = m.noteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !note.isEmpty { parts.append("想法：\(note)") }
            let ocr = m.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !ocr.isEmpty { parts.append("照片文字：\(String(ocr.prefix(200)))") }
            if parts.count == 1 { parts.append("拍了\(m.photoCount)张照片") }
            return parts.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }

    /// 注入纪要 prompt 的「会中手写笔记」摘要（时间戳 + 识别文字）；无则 nil。
    /// 与 `momentsPromptSummary` 平级，让 AI 生成的纪要 / 待办兼顾用户手写记录。
    public var handwritingPromptSummary: String? {
        guard !handwritingNotes.isEmpty else { return nil }
        let lines = handwritingNotes
            .sorted { $0.startSeconds < $1.startSeconds }
            .compactMap { n -> String? in
                let text = n.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { return nil }
                return "[\(n.sourceTime)] 手写：\(String(text.prefix(500)))"
            }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 便捷访问分段（解码失败返回空，不抛错以保 App 不崩）。
    public var segments: [TranscriptSegment] {
        get {
            if let segmentsCache { return segmentsCache }
            let decoded = (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
            segmentsCache = decoded
            return decoded
        }
        set {
            // 编码失败保留旧 blob，禁止静默写成空 Data 抹掉字幕
            if let encoded = try? JSONEncoder().encode(newValue) {
                segmentsData = encoded
                segmentsCache = newValue
            }
        }
    }

    /// LLM 润色后的转写分段（与 `segments` 一一对应，同 id/时间戳，text 已润色）；未润色返回空。
    public var polishedSegments: [TranscriptSegment] {
        guard let data = polishedSegmentsData else { return [] }
        return (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
    }

    public var speakers: [Speaker] {
        get {
            if let speakersCache { return speakersCache }
            let decoded = (try? JSONDecoder().decode([Speaker].self, from: speakersData)) ?? []
            speakersCache = decoded
            return decoded
        }
        set {
            speakersData = (try? JSONEncoder().encode(newValue)) ?? Data()
            speakersCache = newValue
        }
    }

    /// 开录时自动采集的会议地点（提示性，非精确）。解码失败返回 nil，不抛错。
    public var location: MeetingLocation? {
        get {
            guard let data = locationData else { return nil }
            return try? JSONDecoder().decode(MeetingLocation.self, from: data)
        }
        set {
            if let newValue {
                locationData = try? JSONEncoder().encode(newValue)
            } else {
                locationData = nil
            }
        }
    }

    /// UI 直用展示文案（null-safe；空字符串也视为无地点）。
    public var locationDisplay: String? {
        guard let label = location?.label.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        return label
    }

    // MARK: - UI 投影（@Model 直驱）

    public var listStatus: MeetingListStatus { MeetingListStatus(phase: phase) }
    public var attendeeCount: Int { speakers.count }
    public var todoCount: Int { actionItems.count }

    public var dateText: String {
        startedAt.formatted(
            Date.FormatStyle()
                .month(.twoDigits).day(.twoDigits)
                .hour(.defaultDigits(amPM: .omitted)).minute()
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    /// 首页时间栏：仅时刻。
    public var timeText: String {
        startedAt.formatted(
            Date.FormatStyle()
                .hour(.defaultDigits(amPM: .omitted)).minute()
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    /// 首页列表相对时间：今天只显示时刻；非今天显示「昨天 / 周几 / 月日 + 时刻」。
    public var listWhenText: String {
        let cal = Calendar.current
        let time = timeText
        if cal.isDateInToday(startedAt) { return time }
        if cal.isDateInYesterday(startedAt) { return "昨天 \(time)" }
        if cal.isDate(startedAt, equalTo: .now, toGranularity: .weekOfYear) {
            let weekday = startedAt.formatted(
                Date.FormatStyle()
                    .weekday(.abbreviated)
                    .locale(Locale(identifier: "zh_CN"))
            )
            return "\(weekday) \(time)"
        }
        let day = startedAt.formatted(
            Date.FormatStyle()
                .month(.defaultDigits).day()
                .locale(Locale(identifier: "zh_CN"))
        )
        return "\(day) \(time)"
    }

    /// 非今天日分组标签：昨天 / 本周周几 / 月日。
    public var listDayGroupLabel: String {
        let cal = Calendar.current
        if cal.isDateInYesterday(startedAt) { return "昨天" }
        if cal.isDate(startedAt, equalTo: .now, toGranularity: .weekOfYear) {
            return startedAt.formatted(
                Date.FormatStyle()
                    .weekday(.wide)
                    .locale(Locale(identifier: "zh_CN"))
            )
        }
        return startedAt.formatted(
            Date.FormatStyle()
                .month(.abbreviated).day()
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    public var listDayGroupKey: String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: startedAt)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    public var durationText: String {
        let total = Int(durationSeconds.rounded())
        if total <= 0 { return phase == .live ? "进行中" : "—" }
        let h = total / 3600
        let m = (total % 3600) / 60
        // 用「分钟」而非「分」，避免列表里被读成打分
        if h > 0 { return "\(h) 小时 \(m) 分钟" }
        if m == 0 { return "不到 1 分钟" }
        return "\(m) 分钟"
    }

    /// 列表一行预览：优先纪要 tldr，否则空。
    public var tldrPreview: String? {
        guard let raw = latestSummary?.tldr else {
            return nil
        }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 最新一版纪要产出（按 version 降序，同版本取 createdAt 更新者）。
    public var latestSummaryOutput: AIOutput? {
        outputs
            .filter { $0.kind == .summary }
            .max { lhs, rhs in
                (lhs.version, lhs.createdAt) < (rhs.version, rhs.createdAt)
            }
    }

    public var latestSummary: MeetingSummary? { latestSummaryOutput?.summaryPayload }

    public var summaryVersionCount: Int {
        outputs.filter { $0.kind == .summary }.count
    }

    // MARK: - 标题生命周期

    /// 开录时的占位标题（时间戳）。用户改名或 AI 回写后不再视为占位。
    public static func provisionalTitle(at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return "会议·\(formatter.string(from: date))"
    }

    /// 仍是系统占位名时，允许纪要管线回写短标题。
    public var hasProvisionalTitle: Bool {
        title.hasPrefix("会议·")
    }

    /// 仅在占位标题时采纳生成结果；已改名 / 已生成过则保留。
    public func adoptGeneratedTitle(_ raw: String) {
        guard hasProvisionalTitle else { return }
        let cleaned = Self.refineTitle(raw)
        guard !cleaned.isEmpty else { return }
        title = cleaned
    }

    /// 清洗模型给出的短标题：去 `#`、压空白、截断到约 16 字。
    public static func refineTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        s = s
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        let banned = ["会议纪要", "会议记录", "纪要", "总结", "Summary", "Meeting"]
        if banned.contains(where: { s.caseInsensitiveCompare($0) == .orderedSame }) { return "" }
        if s.count <= 16 { return s }
        let head = s.prefix(16)
        if let idx = head.lastIndex(where: { "·•—- ".contains($0) }) {
            let cut = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
            if cut.count >= 4 { return cut }
        }
        return String(s.prefix(16))
    }
}

/// 转写稿版本（原始 / 润色），润色稿可改写文本但保留时间戳以便溯源。
@Model
public final class TranscriptVersion {
    @Attribute(.unique) public var id: UUID
    public var kind: TranscriptKind
    public var segmentsData: Data
    public var modelId: String?            // 润色用的模型（原始稿为 nil）
    public var createdAt: Date
    public var meeting: Meeting?

    public init(id: UUID = UUID(),
                kind: TranscriptKind,
                segments: [TranscriptSegment],
                modelId: String? = nil,
                meeting: Meeting? = nil) {
        self.id = id
        self.kind = kind
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.modelId = modelId
        self.createdAt = Date()
        self.meeting = meeting
    }

    public var segments: [TranscriptSegment] {
        get { (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? [] }
        set { segmentsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

/// 会议地点快照（开录时自动定位 + 反地理编码）。仅本地、提示性，不要求精确。
public struct MeetingLocation: Codable, Hashable, Sendable {
    /// 主展示文本（如「国贸三期」「北京市朝阳区建国门外大街」）。
    public var label: String
    /// 坐标（留作将来小地图；v1 仅展示 label）。
    public var coordinate: Coordinate?
    public var source: Source
    public var capturedAt: Date

    public init(label: String,
                coordinate: Coordinate? = nil,
                source: Source = .gps,
                capturedAt: Date = .now) {
        self.label = label
        self.coordinate = coordinate
        self.source = source
        self.capturedAt = capturedAt
    }

    public struct Coordinate: Codable, Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public enum Source: String, Codable, Sendable {
        case gps        // 开录时自动定位
        case manual     // 用户手动填（v1 暂不启用，保留扩展）
    }

    // MARK: 标签组装（纯函数，便于单测）

    /// 反编码字段投影（脱离 CLPlacemark，便于纯函数处理与单测）。
    public struct LabelInput: Sendable, Hashable {
        public var name: String?         // POI / 具体地点名（最贴近「在哪开的」）
        public var locality: String?     // 市 / 区
        public var thoroughfare: String? // 街道
        public init(name: String?, locality: String?, thoroughfare: String?) {
            self.name = name
            self.locality = locality
            self.thoroughfare = thoroughfare
        }
    }

    /// 组装可读地点文案；取不到任何可读字段返回 nil（调用方据此不落库）。
    /// 优先 POI 名；退而求其次「区 + 街道」；都无则 nil。结果截断到 20 字以内。
    public static func composeLabel(_ input: LabelInput) -> String? {
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let name = clean(input.name), Self.isReadable(name) {
            return String(name.prefix(20))
        }
        let area = [clean(input.locality), clean(input.thoroughfare)]
            .compactMap { $0 }
            .joined(separator: " ")
        if Self.isReadable(area) {
            return String(area.prefix(20))
        }
        return nil
    }

    /// 过滤「无字母」占位串（纯数字 / 坐标），要求至少 2 个字母或汉字。
    private static func isReadable(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.count >= 2
    }
}
