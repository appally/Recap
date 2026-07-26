import XCTest
@testable import RecapASR

final class CoreMLInferenceGateTests: XCTestCase {

    /// 并发 3 个 exclusive 闭包，验证任意时刻最多 1 个在执行（#661 串行保证）。
    func testExclusiveIsSerial() async {
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
        _ = await [a, b, c]

        let maxC = await rec.maxObserved()
        XCTAssertEqual(maxC, 1, "exclusive 应严格串行，最大并发必须为 1（实际 \(maxC)），否则 #661 会崩")
    }

    /// 串行执行后，所有任务都应完成（无死锁/泄漏令牌）。
    func testAllWorkCompletes() async {
        let gate = CoreMLInferenceGate.shared
        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await gate.exclusive { await counter.inc() }
                }
            }
        }
        let n = await counter.get()
        XCTAssertEqual(n, 5, "5 个串行任务都应执行完成")
    }
}
