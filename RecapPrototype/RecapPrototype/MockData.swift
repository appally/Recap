import Foundation

// MARK: - 说话人

extension Speaker {
    static let zhangming = Speaker(id: "s1", name: "张明", colorIndex: 0)
    static let lihua = Speaker(id: "s2", name: "李华", colorIndex: 1)
    static let lin = Speaker(id: "s3", name: "小林", colorIndex: 2)
}

// MARK: - 实时字幕脚本（LIVE 态逐块流式喂入）

extension TranscriptBlock {
    static let script: [TranscriptBlock] = [
        .init(id: "t1", speaker: .zhangming, timestamp: "14:31",
              raw: "那个我们这周把方案再过一下啊，预算这块我看了下",
              polished: "本周需复盘方案，核对预算", isFinal: true),
        .init(id: "t2", speaker: .zhangming, timestamp: "14:31",
              raw: "我觉得移动端这块投入得加大",
              polished: "建议加大移动端投入", isFinal: true),
        .init(id: "t3", speaker: .lihua, timestamp: "14:32",
              raw: "报价的话单台大概四百二吧，加上那个一年的服务费",
              polished: "单设备报价约 420 元，含一年服务", isFinal: true),
        .init(id: "t4", speaker: .zhangming, timestamp: "14:33",
              raw: "那移动端这块我们这季度就提到总预算的百分之三十",
              polished: "本季移动端投入提至总预算 30%", isFinal: false),
        .init(id: "t5", speaker: .lihua, timestamp: "14:34",
              raw: "行，那我周五之前把评审方案弄出来",
              polished: "李华本周五前出移动端评审方案", isFinal: false),
        .init(id: "t6", speaker: .zhangming, timestamp: "14:35",
              raw: "客户的报价我再确认一下",
              polished: "张明跟进确认客户报价", isFinal: false),
    ]
}

// MARK: - 待办（含 null-safe 低置信项）

extension ActionItem {
    static let preview: [ActionItem] = [
        // 待确认（低置信）置顶 -- null-safe 的「2 分钟人审」入口
        ActionItem(id: "a2", title: "确认客户报价",
                   assigneeInitial: "明", assigneeColorIndex: 0,
                   dueText: nil, dueUrgent: false,
                   sourceTime: "14:35", sourceSpeaker: "张明",
                   confidence: .low, status: .pending),
        ActionItem(id: "a1", title: "出移动端评审方案",
                   assigneeInitial: "华", assigneeColorIndex: 1,
                   dueText: "周五前", dueUrgent: true,
                   sourceTime: "14:34", sourceSpeaker: "李华",
                   confidence: .high, status: .confirmed),
        ActionItem(id: "a3", title: "整理报价对比表",
                   assigneeInitial: "明", assigneeColorIndex: 0,
                   dueText: "下周二", dueUrgent: false,
                   sourceTime: "14:50", sourceSpeaker: "张明",
                   confidence: .high, status: .pending),
    ]
}

// MARK: - 纪要内容

extension MeetingSummary {
    static let preview = MeetingSummary(
        tldr: "本次会议敲定移动端预算提至 30%，李华负责本周五前出评审方案；张明跟进确认客户报价。",
        decisions: [
            "移动端投入提至总预算 30%",
            "采用「单设备 420 元」报价口径",
        ],
        openQuestions: [
            "是否纳入 iPad 端首批？—— 张明下周给结论",
        ]
    )
}

// MARK: - 首页列表

extension Meeting {
    static let list: [Meeting] = [
        Meeting(id: "m1", title: "周会·产品评审", dateText: "07/24 14:14",
                durationText: "38 分", attendeeCount: 3, todoCount: 3, listStatus: .live),
        Meeting(id: "m2", title: "客户访谈·锐捷", dateText: "07/24 11:02",
                durationText: "52 分", attendeeCount: 2, todoCount: 3, listStatus: .done),
        Meeting(id: "m3", title: "1on1·小林", dateText: "07/24 09:30",
                durationText: "30 分", attendeeCount: 2, todoCount: 0, listStatus: .done),
        Meeting(id: "m4", title: "需求评审·v2.3", dateText: "07/22 16:00",
                durationText: "1 小时 12 分", attendeeCount: 5, todoCount: 6, listStatus: .done),
    ]
}
