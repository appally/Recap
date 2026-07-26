import Foundation
import SwiftData
import UIKit
import RecapModels

/// SwiftData ModelContainer 装配 + 首次启动预置数据。
public enum RecapDataContainer {

    /// 投产 schema：会议聚合根 + 转写版本 + LLM 产出 + 待办 + BYOK 配置。
    public static let schema = Schema([
        Meeting.self,
        MeetingBrief.self,
        TranscriptVersion.self,
        AIOutput.self,
        ActionItem.self,
        Moment.self,
        LLMProviderConfig.self,
        ChatSession.self,
        ChatMessageRecord.self,
        AgentStepRecord.self,
        AgentTask.self,
    ])

    /// 全局容器（make() 在 App 启动时单线程写入一次，之后只读；供 AppIntents EntityQuery 等
    /// 无 ModelContext 上下文处复用）。nonisolated(unsafe)：launch-time 一次性写入，随后只读。
    public nonisolated(unsafe) private(set) static var shared: ModelContainer?

    /// 创建持久化容器；首次启动写入默认 DeepSeek 配置与示例会议。
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        // 真机首次启动时 Application Support 可能尚不存在，
        // SwiftData 默认 default.store 会先报 errno 2 再自愈；这里预先创建以免噪声/竞态。
        let storeURL: URL?
        if inMemory {
            storeURL = nil
        } else {
            let fm = FileManager.default
            let appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            storeURL = appSupport.appendingPathComponent("Recap.store")
        }

        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let seedContext = ModelContext(container)
            try seedIfNeeded(in: seedContext)
            Self.shared = container
            return container
        } catch {
            // 开发期 schema 演进（如新增 MeetingBrief）可能导致旧 store 无法轻量迁移。
            // 清库重建，避免真机白屏；正式版应改为 VersionedSchema + MigrationPlan。
            if let storeURL {
                try? FileManager.default.removeItem(at: storeURL)
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let seedContext = ModelContext(container)
                try seedIfNeeded(in: seedContext)
                Self.shared = container
                return container
            }
            throw error
        }
    }

    public static func seedIfNeeded(in context: ModelContext) throws {
        try seedDefaultProviderIfNeeded(in: context)
        try seedSampleMeetingsIfNeeded(in: context)
    }

    /// 播种 / 补齐预置 LLM 供应商；已有项不覆盖用户改过的 model。
    public static func seedDefaultProviderIfNeeded(in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<LLMProviderConfig>())
        let existingAccounts = Set(existing.map(\.keychainAccount))
        var didInsert = false

        let hasDefault = existing.contains(where: \.isDefault)
        for template in LLMProviderTemplate.featured {
            guard !existingAccounts.contains(template.keychainAccount) else { continue }
            context.insert(LLMProviderConfig(
                name: template.displayName,
                baseURL: template.baseURL,
                model: template.defaultModel,
                keychainAccount: template.keychainAccount,
                supportsThinking: template.supportsThinking,
                isDefault: template == .deepseek && !hasDefault
            ))
            didInsert = true
        }

        // 确保恰好一个默认
        let all = try context.fetch(FetchDescriptor<LLMProviderConfig>())
        if !all.contains(where: \.isDefault), let deepseek = all.first(where: {
            $0.keychainAccount == LLMPresets.deepSeekKeychainAccount
        }) {
            deepseek.isDefault = true
            didInsert = true
        }

        if didInsert { try context.save() }
    }

    /// 空库时写入 1 条示例会后会议，方便 P4 UI 验收。
    public static func seedSampleMeetingsIfNeeded(in context: ModelContext) throws {
        var descriptor = FetchDescriptor<Meeting>()
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return }

        let speakers = [
            Speaker(id: "s1", name: "张明", colorIndex: 0),
            Speaker(id: "s2", name: "李华", colorIndex: 1),
            Speaker(id: "s3", name: "小林", colorIndex: 2),
        ]
        let segments = [
            TranscriptSegment(startSeconds: 0, endSeconds: 12, speakerId: "s1",
                              text: "那个我们这周把方案再过一下啊，预算这块我看了下"),
            TranscriptSegment(startSeconds: 12, endSeconds: 20, speakerId: "s1",
                              text: "我觉得移动端这块投入得加大"),
            TranscriptSegment(startSeconds: 20, endSeconds: 35, speakerId: "s2",
                              text: "报价的话单台大概四百二吧，加上那个一年的服务费"),
            TranscriptSegment(startSeconds: 35, endSeconds: 50, speakerId: "s1",
                              text: "那移动端这块我们这季度就提到总预算的百分之三十"),
            TranscriptSegment(startSeconds: 50, endSeconds: 62, speakerId: "s2",
                              text: "行，那我周五之前把评审方案弄出来"),
            TranscriptSegment(startSeconds: 62, endSeconds: 70, speakerId: "s1",
                              text: "客户的报价我再确认一下"),
        ]

        let meeting = Meeting(
            title: "周会·产品评审",
            startedAt: Date(),
            durationSeconds: 38 * 60,
            phase: .review,
            segments: segments,
            speakers: speakers
        )
        context.insert(meeting)

        let summary = MeetingSummary(
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
        let summaryData = (try? JSONEncoder().encode(summary)) ?? Data()
        context.insert(AIOutput(
            kind: .summary,
            payloadData: summaryData,
            modelId: LLMPresets.deepSeekPro,
            promptHash: "seed",
            meeting: meeting
        ))

        let friday = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(weekday: 6),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(3 * 24 * 3600)

        context.insert(ActionItem(
            task: "确认客户报价",
            owner: "张明",
            ownerSource: .inferred,
            due: nil,
            confidence: 0.42,
            evidenceQuote: "客户的报价我再确认一下",
            startSeconds: 62,
            status: .draft,
            meeting: meeting
        ))
        context.insert(ActionItem(
            task: "出移动端评审方案",
            owner: "李华",
            ownerSource: .explicit,
            due: friday,
            priority: .high,
            confidence: 0.91,
            evidenceQuote: "那我周五之前把评审方案弄出来",
            startSeconds: 50,
            status: .confirmed,
            meeting: meeting
        ))
        context.insert(ActionItem(
            task: "整理报价对比表",
            owner: "张明",
            ownerSource: .explicit,
            due: Date().addingTimeInterval(5 * 24 * 3600),
            confidence: 0.78,
            evidenceQuote: nil,
            startSeconds: 80,
            status: .draft,
            meeting: meeting
        ))

        // 示例底稿：方便验收「对照议程 / 关联上场」
        let sampleBrief = MeetingBrief(
            sources: [
                BriefSource(role: .agenda, kind: .paste, title: "示例议程")
            ],
            agenda: [
                AgendaItem(order: 1, title: "开场同步", ownerHint: "张明"),
                AgendaItem(order: 2, title: "移动端预算", ownerHint: "李华"),
                AgendaItem(order: 3, title: "客户报价确认", ownerHint: "张明"),
            ],
            openItems: [
                OpenItem(text: "整理报价对比表", ownerHint: "张明", resolution: "open")
            ],
            entityHints: ["张明", "李华", "移动端"],
            meeting: meeting
        )
        sampleBrief.rebuildPromptSummary()
        context.insert(sampleBrief)
        meeting.brief = sampleBrief

        // 一条更早的会议，撑起「本周」分组
        let earlier = Meeting(
            title: "客户访谈·锐捷",
            startedAt: Date().addingTimeInterval(-2 * 24 * 3600),
            durationSeconds: 52 * 60,
            phase: .review,
            speakers: [speakers[0], speakers[1]]
        )
        context.insert(earlier)

        // 示例会议时刻（白板快照）：验证「会中拍照 → 时间轴锚定 → 回看卡片」渲染。
        // 仅演示数据；真机由 MomentCaptureOverlay 实拍产生真实照片。
        let sampleMoment = Moment(startSeconds: 20, kind: .photo, meeting: meeting)
        context.insert(sampleMoment)
        if let data = Self.placeholderPhotoData() {
            let rel = "Meetings/\(meeting.id.uuidString)/photos/\(sampleMoment.id.uuidString)/0.jpg"
            if let url = try? Self.supportURL(appendRelative: rel) {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
                sampleMoment.photoRelativePaths = [rel]
            }
        }

        try context.save()
    }

    // MARK: - 演示数据辅助

    /// 青瓷底白板样占位图（仅 seed 演示用，让模拟器直观看到 Moment 卡片）。
    private static func placeholderPhotoData() -> Data? {
        let size = CGSize(width: 640, height: 480)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.37, green: 0.54, blue: 0.41, alpha: 1.0).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.85).setFill()
            for i in 0..<4 {
                let y = 110.0 + Double(i) * 70.0
                let w = 420.0 - Double(i) * 45.0
                context.fill(CGRect(x: 70, y: y, width: w, height: 6))
            }
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    private static func supportURL(appendRelative relative: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appendingPathComponent(relative)
    }
}
