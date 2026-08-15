import Foundation

/// mmap PCM 的零拷贝 Float32 随机访问视图（16k mono raw Float 文件）。
///
/// 供 FluidAudio `performCompleteDiarization<C: RandomAccessCollection>` 泛型路径直接消费
/// mmap 页，替代整场 `[Float]` 物化——2h 会议匿名堆 ~460MB（3h ~691MB）降为 mmap 的
/// file-backed 页（clean page 可被内核逐页回收重读，jetsam 压力远低于匿名内存），
/// 引擎侧只保留固定的 chunkBuffer。
///
/// 设计要点：
/// - `SubSequence = Self`：切片 O(1)（引擎按 chunk 取 `samples[range]`），不经 `Slice` 中转。
/// - `withContiguousStorageIfAvailable` 暴露重基裸指针：引擎的 vDSP 拷贝快路径直接命中，
///   不触发逐元素 subscript 慢路径（1 亿样本级 × 每次 `withUnsafeBytes` 会拖慢分钟级推理）。
/// - 字节数非 4 倍数时**向下取整**（与旧 `bindMemory + Array` 语义一致，静默丢尾部残字节）。
/// - 只含不可变 let（值语义）→ Sendable，可跨 actor 传入 `diarize`（async）。
public struct MappedFloatSamples: RandomAccessCollection, Sendable {
    public typealias Element = Float
    public typealias Index = Int
    public typealias SubSequence = MappedFloatSamples

    public let data: Data
    /// 本视图的起始样本下标（切片偏移）。
    public let offset: Int
    /// 本视图样本数。
    public let floatCount: Int

    /// 根视图（覆盖整个 mmap Data）。
    public init(data: Data) {
        self.data = data
        self.offset = 0
        self.floatCount = data.count / MemoryLayout<Float>.size
    }

    private init(data: Data, offset: Int, floatCount: Int) {
        self.data = data
        self.offset = offset
        self.floatCount = floatCount
    }

    public var startIndex: Int { offset }
    public var endIndex: Int { offset + floatCount }
    public var isEmpty: Bool { floatCount == 0 }
    public var count: Int { floatCount }

    public subscript(position: Int) -> Float {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(
                fromByteOffset: position * MemoryLayout<Float>.size, as: Float.self)
        }
    }

    public subscript(bounds: Range<Int>) -> MappedFloatSamples {
        MappedFloatSamples(data: data, offset: bounds.lowerBound, floatCount: bounds.count)
    }

    public func withContiguousStorageIfAvailable<R>(
        _ body: (UnsafeBufferPointer<Float>) throws -> R
    ) rethrows -> R? {
        try data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            let view = UnsafeBufferPointer(rebasing: floats[offset..<offset + floatCount])
            return try body(view)
        }
    }
}
