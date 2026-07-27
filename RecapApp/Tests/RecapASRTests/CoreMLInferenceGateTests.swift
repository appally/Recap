import XCTest
@testable import RecapASR

final class CoreMLInferenceGateTests: XCTestCase {

    /// 并发 3 个 exclusive 闭包，验证任意时刻最多 1 个在执行（#661 串行保证）。
    func testExclusiveIsSerial() async throws {
        let gate = CoreMLInferenceGate.shared

        actor Recorder {
            var running = 0
            var maxConcurrent = 0
            func enter() { running += 1; maxConcurrent = max(maxConcurrent, running) }
            func leave() { running -= 1 }
            func maxObserved() -> Int { maxConcurrent }
        }
        let rec = Recorder()

        async let a: Void = gate.exclusive {
            await rec.enter()
            try? await Task.sleep(for: .milliseconds(40))
            await rec.leave()
        }
        async let b: Void = gate.exclusive {
            await rec.enter()
            try? await Task.sleep(for: .milliseconds(40))
            await rec.leave()
        }
        async let c: Void = gate.exclusive {
            await rec.enter()
            try? await Task.sleep(for: .milliseconds(40))
            await rec.leave()
        }
        _ = try await [a, b, c]

        let maxC = await rec.maxObserved()
        XCTAssertEqual(maxC, 1, "exclusive 应严格串行，最大并发必须为 1（实际 \(maxC)），否则 #661 会崩")
    }

    /// 串行执行后，所有任务都应完成（无死锁/泄漏令牌）。
    func testAllWorkCompletes() async throws {
        let gate = CoreMLInferenceGate.shared
        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await gate.exclusive { await counter.inc() }
                }
            }
        }
        let n = await counter.get()
        XCTAssertEqual(n, 5, "5 个串行任务都应执行完成")
    }

    /// 排队中的 waiter 被取消时应抛 `CancellationError`，且不泄漏令牌（后续 exclusive 仍可获取）。
    /// 验证 cancelPostMeetingCompute 能真正中断在等的会后 CoreML 任务。
    func testCancelledWaiterDoesNotLeakToken() async throws {
        let gate = CoreMLInferenceGate.shared

        // 1) 占用门足够久，确保 waiter 进队列后再取消
        async let holder: Void = gate.exclusive {
            try? await Task.sleep(for: .milliseconds(300))
        }

        // 2) 等 holder 拿到令牌，再排队一个 waiter 并立即取消
        try? await Task.sleep(for: .milliseconds(50))
        let waiterTask = Task<Void, Error> {
            try await gate.exclusive {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        waiterTask.cancel()

        do {
            try await waiterTask.value
            XCTFail("被取消的 waiter 应抛 CancellationError，却正常返回")
        } catch is CancellationError {
            // 期望路径
        } catch {
            XCTFail("应抛 CancellationError，实际：\(error)")
        }

        // 3) 等 holder 释放
        _ = try? await holder

        // 4) 门仍可用：被取消的 waiter 未消费令牌 → 后续 exclusive 正常获取
        let probe = try? await gate.exclusive { true }
        XCTAssertEqual(probe, true, "被取消的 waiter 不应泄漏令牌——后续 exclusive 必须能获取")
    }
}
