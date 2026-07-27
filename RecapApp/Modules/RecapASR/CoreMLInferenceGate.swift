import Foundation

/// CoreML 推理串行门：保证端侧 ASR / 说话人分离的 CoreML 推理段互斥执行。
///
/// **背景**：iOS CoreML/E5RT 运行时在「同进程并发跑多个 CoreML 模型」时会破坏共享
/// scratch 缓冲区，触发 `EXC_BAD_ACCESS`（FluidAudio #661）。SpeakerKit 的 pyannote 与
/// FluidAudio 的 SenseVoice/Paraformer 是两个独立包，但都落点 E5RT——会后重转写与
/// （进 REVIEW 自动触发的）说话人分离一旦时间窗重叠即踩坑。
///
/// 本 gate 是 1-permit 异步锁（actor + FIFO 队列），把所有 CoreML 推理闭包串行化。
/// **模型加载/卸载不必进 gate**（只串行化「推理」）。
///
/// **取消语义**：`exclusive` 是 `throws`。排队等待令牌时若父 Task 被取消，该 waiter 会被
/// 从队列移除并抛 `CancellationError`（不消费令牌，不泄漏）。已进入 `work` 的取消需调用方在
/// `work` 内部于推理**间隙** `try Task.checkCancellation()`（如 chunk 边界）——此时无推理在飞，
/// 抛错后 `defer release()` 干净释放令牌，避免与下一次推理并发触发 #661。
public actor CoreMLInferenceGate {
    public static let shared = CoreMLInferenceGate()

    private var busy = false
    private var waiters: [Waiter] = []

    private init() {}

    /// 串行执行一段 CoreML 推理闭包：同一时刻全局只有一个 `work` 在跑。
    /// 调用方在 `work` 内构造并调用 CoreML 推理（如 `kit.diarize(...)` / `manager.transcribe(...)`）。
    public func exclusive<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async throws {
        if !busy { busy = true; return }
        // 已占用 → 排队；生成 id 供 continuation 体与 onCancel 共享，实现精确定位取消
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) -> Void in
                // 此闭包同步运行在 actor 上下文，安全触碰 self.waiters
                self.waiters.append(Waiter(id: id, cont))
            }
        } onCancel: { [weak self] in
            // onCancel 是同步非隔离闭包：调度一次 actor 调用做实际移除（不消费令牌）
            guard let self else { return }
            Task { await self.cancelWaiter(id: id) }
        }
        // 走到这里 = 被 release 交棒了令牌（busy 已由 release 保持为 true）
        busy = true
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            // busy 保持 true：直接把令牌交给下一个 waiter，无并发空隙
        } else {
            busy = false
        }
    }

    /// 取消处理器调度：按 id 移除并唤醒对应 waiter（抛 `CancellationError`）。
    /// 若该 waiter 已被 `release` 交棒令牌（已移出队列），此处找不到 → no-op，令牌不泄漏。
    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: idx).resumeThrowing(CancellationError())
    }

    /// 单次唤醒守卫的排队 waiter（resume-once 防双唤）。
    private final class Waiter: @unchecked Sendable {
        let id: UUID
        private let continuation: CheckedContinuation<Void, Error>
        private var resumed = false

        init(id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
            self.id = id
            self.continuation = continuation
        }

        func resume() {
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }

        func resumeThrowing(_ error: Error) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: error)
        }
    }
}
