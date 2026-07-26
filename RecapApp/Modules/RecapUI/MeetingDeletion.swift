import Foundation
import SwiftData
import RecapModels
import RecapASR

/// 会议硬删：SwiftData cascade（含 `chatSessions`）+ 本地 PCM 目录。
enum MeetingDeletion {
    static func delete(_ meeting: Meeting, in context: ModelContext) {
        let id = meeting.id
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
