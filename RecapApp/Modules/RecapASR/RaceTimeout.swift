import Foundation

/// 「到点即放弃」的竞速超时工具。
///
/// 背景：task group + timer 的经典超时写法（`group.next()` 先到 + `cancelAll`）有结构性
/// 缺陷——`withTaskGroup` 在 body 退出前会**隐式 await 所有子任务**，而子任务里的
/// `await someTask.value`、挂死的框架调用（`analyzer.start`、`URLSessionWebSocketTask.send`
/// 等）不响应协作取消，于是「超时」在最需要的场景形同虚设，调用方无限挂起
/// （表现为 UI 永久停在「正在收尾」）。
///
/// 本工具用无结构 Task + resume-once 门闩竞速：到点直接返回，**放弃等待**滞留的子任务
/// （其结果作废，资源由调用方在超时路径自行善后，如取消 WS 解除 send 挂起）。
public enum RaceTimeout {

    /// Void 版：operation 至多等到 `seconds` 秒，超时即放弃返回。
    public static func run(
        seconds: Double,
        operation: @escaping @Sendable () async -> Void
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnceGate()
            Task {
                await operation()
                gate.fire(cont)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.fire(cont)
            }
        }
    }

    /// 取值版：`fetch` 在 `seconds` 秒内完成返回其值；超时返回 nil（放弃等待，fetch 的
    /// 结果作废）。`drained` 用于事后区分「完成」与「超时」（如决定是否取消 WS）。
    public static func value<T: Sendable>(
        seconds: Double,
        drained: DrainFlag? = nil,
        fetch: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let gate = ResumeOnceGate()
            Task {
                let value = await fetch()
                drained?.set(true)
                gate.fire(cont, value: value)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.fire(cont, value: nil)
            }
        }
    }
}

/// resume-once 门闩：竞速两个 Task，先到者恢复 continuation（后到者 no-op）。
final class ResumeOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func fire(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first { cont.resume() }
    }

    func fire<T: Sendable>( _ cont: CheckedContinuation<T?, Never>, value: T?) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first { cont.resume(returning: value) }
    }
}

/// 竞速「是否按期完成」的标志（锁保护，@Sendable 闭包安全读写）。
public final class DrainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func set(_ done: Bool) {
        lock.lock()
        value = done
        lock.unlock()
    }
}
