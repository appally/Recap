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
    private var entries: [UUID: (task: Task<Void, Never>, token: UUID)] = [:]

    /// 登记管线 Task。`token` 由调用方在创建 Task 前生成，并同一传入管线 defer 与本方法：
    /// 同一会议若在旧 Task 退出前又登记新 Task（新 token），旧 Task 的 defer 因 token 不匹配
    /// 不会抹掉新条目，避免删除竞态写入（旧版无条件置 nil 的隐患）。
    func register(_ task: Task<Void, Never>, token: UUID, for meetingID: UUID) {
        entries[meetingID] = (task, token)
    }

    /// 管线 Task 自身在任意退出路径（完成 / 失败 / 取消）调用；仅当 token 仍是当前登记项时移除，
    /// 避免旧 Task 的 defer 抹掉后来者登记的新 Task。
    func unregister(token: UUID, for meetingID: UUID) {
        guard entries[meetingID]?.token == token else { return }
        entries[meetingID] = nil
    }

    /// 删除会议前调用：协作式取消纪要管线（管线在下一 `Task.isCancelled` 检查点退出，
    /// 并经 catch 兜底不再写回部分结果）。
    func cancel(for meetingID: UUID) {
        entries[meetingID]?.task.cancel()
        entries[meetingID] = nil
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
        // save 成功才删音频文件：失败时保留会议记录与音频（刷新后会议重现，等价于删除未生效），
        // 避免「DB 仍存但音频已删」的不一致孤儿。
        do {
            try context.save()
        } catch {
            return
        }
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
        do {
            try context.save()
        } catch {
            return
        }
        for id in ids {
            MeetingAudioStore.deleteMeetingAudio(meetingId: id)
        }
    }
}
