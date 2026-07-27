import Foundation

/// 会后重算（端侧 ASR / 说话人分离）的推理超时错误。
///
/// 与 `CancellationError` 区分：
/// - `InferenceTimeoutError`：操作在预算墙钟内未完成（如 RTF 远超预期 / 推理挂死）。
/// - `CancellationError`：父 Task 被取消（用户切后台 / `cancelPostMeetingCompute`）。
/// 上层据此给不同 UI 文案（"超时" vs "已取消"），并决定是否保留可重试状态。
public enum InferenceTimeoutError: Error, LocalizedError, Sendable {
    case exceeded(seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .exceeded(let seconds): return "推理超时（\(Int(seconds))s）"
        }
    }
}

/// 给一段异步操作加墙钟超时。
///
/// - 超时：抛 `InferenceTimeoutError.exceeded`。
/// - 父取消：**穿透 `CancellationError`**（不误报为超时）——靠 `Task.sleep` 自身在被取消时抛
///   `CancellationError` 实现，故用 `try` 而非 `try?`。
/// - 操作先完成：`cancelAll()` 取消计时任务后返回结果。
///
/// ⚠️ 仅靠 Swift 协作式取消；若 `operation` 内部是不响应取消的同步调用（如 CoreML 推理），
/// 超时抛错后该调用仍会在子任务里跑到自然结束。调用方应把本工具放在 CoreML 门**外**
/// （如 `MeetingSession` 层），让门在残余推理结束前保持占用，避免与下一次推理并发触发 #661。
public func withThrowingTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))   // 被取消时抛 CancellationError
            throw InferenceTimeoutError.exceeded(seconds: seconds) // 自然醒来 = 超时
        }
        guard let result = try await group.next() else {
            throw InferenceTimeoutError.exceeded(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}
