import Foundation

/// CoreML 推理串行门：保证端侧 ASR / 说话人分离的 CoreML 推理段互斥执行。
///
/// **背景**：iOS CoreML/E5RT 运行时在「同进程并发跑多个 CoreML 模型」时会破坏共享
/// scratch 缓冲区，触发 `EXC_BAD_ACCESS`（FluidAudio #661）。SpeakerKit 的 pyannote 与
/// FluidAudio 的 SenseVoice/Paraformer 是两个独立包，但都落点 E5RT——会后重转写与
/// （进 REVIEW 自动触发的）说话人分离一旦时间窗重叠即踩坑。
///
/// 本 gate 是 1-permit 异步锁（actor + FIFO `CheckedContinuation` 队列），把所有 CoreML
/// 推理闭包串行化。**模型加载/卸载不必进 gate**（只串行化「推理」）。
public actor CoreMLInferenceGate {
    public static let shared = CoreMLInferenceGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// 串行执行一段 CoreML 推理闭包：同一时刻全局只有一个 `work` 在跑。
    /// 调用方在 `work` 内构造并调用 CoreML 推理（如 `kit.diarize(...)` / `manager.transcribe(...)`）。
    public func exclusive<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
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
}
