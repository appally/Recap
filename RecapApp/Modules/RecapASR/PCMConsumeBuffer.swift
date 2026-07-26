import Foundation

/// Int16 PCM 游标缓冲：避免反复 `removeFirst` 的 O(n) 搬移；超上限丢最旧数据。
struct PCMConsumeBuffer: Sendable {
    private var storage: [Int16] = []
    private var start = 0
    /// 约 2 分钟 @16kHz mono Int16
    private let maxSamples: Int

    init(maxSamples: Int = 16_000 * 120) {
        self.maxSamples = max(maxSamples, 16_000)
    }

    var count: Int { storage.count - start }

    mutating func append<C: Sequence>(_ samples: C) where C.Element == Int16 {
        storage.append(contentsOf: samples)
        // 超上限：丢弃最旧，保留尾部 maxSamples
        let total = count
        if total > maxSamples {
            let overflow = total - maxSamples
            start += overflow
            compactIfNeeded(force: true)
        } else {
            compactIfNeeded(force: false)
        }
    }

    mutating func popFirst(_ n: Int) -> [Int16] {
        let available = count
        guard n > 0, available > 0 else { return [] }
        let take = min(n, available)
        let end = start + take
        let chunk = Array(storage[start..<end])
        start = end
        compactIfNeeded(force: false)
        return chunk
    }

    var isEmpty: Bool { count == 0 }

    mutating func drain() -> [Int16] {
        popFirst(count)
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        start = 0
    }

    private mutating func compactIfNeeded(force: Bool) {
        guard start > 0 else { return }
        if force || start > 4_096 {
            storage.removeFirst(start)
            start = 0
        }
    }
}
