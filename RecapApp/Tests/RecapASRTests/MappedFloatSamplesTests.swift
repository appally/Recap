import XCTest
@testable import RecapASR

/// mmap Float 视图语义钉板：FluidAudio 分离管线的零拷贝入参（2h 会议省 ~460MB 匿名堆），
/// contiguous 快路径是 vDSP 拷贝命中的前提，必须与 [Float] 逐点等价。
final class MappedFloatSamplesTests: XCTestCase {
    private func pack(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    func testElementAccessAndTrailingBytesFloor() {
        let data = pack([0.25, -1.5, 3.0]) + Data([0xFF])  // 残尾字节：向下取整丢弃
        let view = MappedFloatSamples(data: data)
        XCTAssertEqual(view.count, 3)
        XCTAssertEqual(view[view.startIndex], 0.25, accuracy: 1e-6)
        XCTAssertEqual(view[view.startIndex + 1], -1.5, accuracy: 1e-6)
        XCTAssertEqual(view[view.startIndex + 2], 3.0, accuracy: 1e-6)
        XCTAssertTrue(view.indexSizeMatches)
    }

    func testSliceMatchesArraySlice() {
        let floats: [Float] = (0..<100).map { Float($0) }
        let view = MappedFloatSamples(data: pack(floats))
        let sub = view[10..<30]
        XCTAssertEqual(sub.startIndex, 10)
        XCTAssertEqual(sub.count, 20)
        XCTAssertEqual(Array(sub), Array(floats[10..<30]))
    }

    func testContiguousStorageFastPath() {
        let floats: [Float] = (0..<64).map { Float($0) * 0.5 }
        let view = MappedFloatSamples(data: pack(floats))
        let sub = view[7..<21]
        // FluidAudio 的 processChunkWithSpeakerTracking 用 withContiguousStorageIfAvailable
        // 走 vDSP_mmov；此路径返回 nil 会退化成逐元素 subscript 慢路径（亿级样本不可接受）。
        let viaContiguous: [Float]? = sub.withContiguousStorageIfAvailable { Array($0) }
        XCTAssertEqual(viaContiguous, Array(floats[7..<21]))
        // 根视图同样命中
        let rootViaContiguous: [Float]? = view.withContiguousStorageIfAvailable { Array($0) }
        XCTAssertEqual(rootViaContiguous, floats)
    }

    func testEmptyAndShortData() {
        XCTAssertEqual(MappedFloatSamples(data: Data()).count, 0)
        XCTAssertTrue(MappedFloatSamples(data: Data()).isEmpty)
        XCTAssertEqual(MappedFloatSamples(data: Data([0x01])).count, 0)  // <4 字节
    }
}

private extension MappedFloatSamples {
    /// 测试辅助断言用（索引语义自检，无生产意义）。
    var indexSizeMatches: Bool { endIndex - startIndex == count }
}
