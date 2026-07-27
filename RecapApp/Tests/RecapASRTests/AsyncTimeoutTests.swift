import XCTest
@testable import RecapASR

final class AsyncTimeoutTests: XCTestCase {

    /// 操作慢于预算 → 抛 `InferenceTimeoutError`（而非 CancellationError）。
    func testTimeoutThrows() async {
        do {
            _ = try await withThrowingTimeout(seconds: 0.2) { () -> Int in
                try? await Task.sleep(for: .seconds(2))   // 远超 0.2s 预算
                return 42
            }
            XCTFail("应抛 InferenceTimeoutError")
        } catch InferenceTimeoutError.exceeded {
            // 期望
        } catch {
            XCTFail("应抛 InferenceTimeoutError，实际：\(error)")
        }
    }

    /// 操作在预算内完成 → 正常返回结果，不抛。
    func testReturnsWithinBudget() async throws {
        let value = try await withThrowingTimeout(seconds: 2.0) { () -> Int in
            try? await Task.sleep(for: .milliseconds(20))
            return 7
        }
        XCTAssertEqual(value, 7)
    }

    /// 父 Task 取消 → 穿透 `CancellationError`（不误报为超时）。
    /// operation 用 `try`（非 `try?`）——真实调用方（engine.transcribe）不会吞取消。
    func testCancellationPropagates() async {
        let task = Task<Void, Error> {
            try await withThrowingTimeout(seconds: 5.0) { () -> Int in
                try await Task.sleep(for: .seconds(5))   // 被取消时抛 CancellationError（不吞）
                return 1
            }
        }
        // 给任务一点时间进入 withThrowingTimeout，再取消
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            try await task.value
            XCTFail("被取消应抛 CancellationError")
        } catch is CancellationError {
            // 期望：取消穿透，非 InferenceTimeoutError
        } catch InferenceTimeoutError.exceeded {
            XCTFail("父取消应穿透为 CancellationError，却被误报为超时")
        } catch {
            XCTFail("应抛 CancellationError，实际：\(error)")
        }
    }
}
