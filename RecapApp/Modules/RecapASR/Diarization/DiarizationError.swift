import Foundation

public enum DiarizationError: LocalizedError, Sendable {
    case missingAudio
    case emptyAudio
    case emptyTranscript
    case engineFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAudio: return "没有可分离的本地录音"
        case .emptyAudio: return "本地录音为空"
        case .emptyTranscript: return "没有可标注的转写分段"
        case .engineFailed(let msg): return "说话人分离失败：\(msg)"
        case .cancelled: return "已取消说话人分离"
        }
    }
}
