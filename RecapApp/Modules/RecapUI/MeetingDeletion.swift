import Foundation
import SwiftData
import RecapModels
import RecapASR

/// 按 meetingID 索引在跑的纪要管线 Task。
///
/// 为什么需要它：纪要 Task 的句柄挂在 `MeetingSession.revealTask` 上，而 session 随详情页
/// `@StateObject` 释放后即不可达（孤儿 Task 仍被并发运行时持有，直到跑完）。首页删除会议时
/// 拿不到该句柄，故需一个独立于 session 生命周期的注册表，按会议 id 跨层取消——否则管线
/// 跑完会把纪要/待办写回已删除的会议，造成脏数据或半残记录复活。
@MainActor
final class MinutesTaskRegistry {
    static let shared = MinutesTaskRegistry()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func register(_ task: Task<Void, Never>, for meetingID: UUID) {
        tasks[meetingID] = task
    }

    /// 管线 Task 自身在任意退出路径（完成 / 失败 / 取消）调用，移除句柄。
    func unregister(for meetingID: UUID) {
        tasks[meetingID] = nil
    }

    /// 删除会议前调用：协作式取消纪要管线（管线在下一 `Task.isCancelled` 检查点退出，
    /// 并经 catch 兜底不再写回部分结果）。
    func cancel(for meetingID: UUID) {
        tasks[meetingID]?.cancel()
        tasks[meetingID] = nil
    }
}

/// 会议硬删：SwiftData cascade（含 `chatSessions`）+ 本地 PCM 目录。
/// 删除前先取消该会议在跑的纪要管线，避免孤儿 Task 跑完后把结果写回已删除的会议。
@MainActor
enum MeetingDeletion {
    static func delete(_ meeting: Meeting, in context: ModelContext) {
        let id = meeting.id
        MinutesTaskRegistry.shared.cancel(for: id)
        // Ask 会话 / 消息 / 步骤：Meeting.chatSessions cascade
        for session in meeting.chatSessions {
            context.delete(session)
        }
        context.delete(meeting)
        try? context.save()
        MeetingAudioStore.deleteMeetingAudio(meetingId: id)
    }

    static func deleteAll(_ meetings: [Meeting], in context: ModelContext) {
        let ids = meetings.map(\.id)
        for id in ids {
            MinutesTaskRegistry.shared.cancel(for: id)
        }
        for meeting in meetings {
            for session in meeting.chatSessions {
                context.delete(session)
            }
            context.delete(meeting)
        }
        try? context.save()
        for id in ids {
            MeetingAudioStore.deleteMeetingAudio(meetingId: id)
        }
    }
}
