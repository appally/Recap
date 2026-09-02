import XCTest
@testable import RecapModels

/// /v1/issue 瞬时网络错误快速重试回归（2026-09-02 日志诊断 P2）：
/// 本地代理/VPN 抖动（-1005 一族，快速失败）一次重试救回；慢失败/持久离线不重试。
final class RecapCredentialIssueRetryTests: XCTestCase {

    /// 调用记录 loader：按脚本逐次返回/抛错。
    private final class ScriptedLoader: @unchecked Sendable {
        private let l = NSLock()
        private var calls = 0
        var callCount: Int { l.lock(); defer { l.unlock() }; return calls }

        private let script: [Result<(Data, URLResponse), Error>]
        init(_ script: [Result<(Data, URLResponse), Error>]) { self.script = script }

        func call(_ req: URLRequest) async throws -> (Data, URLResponse) {
            // NSLock 不允许直接用在 async 上下文（Swift 并发检查），账目走同步方法。
            return try nextScripted().get()
        }

        private func nextScripted() -> Result<(Data, URLResponse), Error> {
            l.lock(); defer { l.unlock() }
            let i = calls
            calls += 1
            return script[min(i, script.count - 1)]
        }
    }

    private func ok(_ req: URLRequest) -> (Data, URLResponse) {
        (Data("{}".utf8),
         HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: - 重试行为

    func testTransientErrorRetriedOnceThenSucceeds() async {
        let req = URLRequest(url: URL(string: "https://example.com/v1/issue")!)
        let loader = ScriptedLoader([
            .failure(URLError(.networkConnectionLost)),
            .success(ok(req)),
        ])
        let result = try? await RecapCredentialProvider.loadDataWithTransientRetry(req, load: loader.call)
        XCTAssertNotNil(result, "-1005 首发失败后应重试成功")
        XCTAssertEqual(loader.callCount, 2)
    }

    func testSecondFailurePropagates() async {
        let req = URLRequest(url: URL(string: "https://example.com/v1/issue")!)
        let loader = ScriptedLoader([
            .failure(URLError(.cannotConnectToHost)),
            .failure(URLError(.cannotConnectToHost)),
        ])
        do {
            _ = try await RecapCredentialProvider.loadDataWithTransientRetry(req, load: loader.call)
            XCTFail("两次失败应抛出")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .cannotConnectToHost)
        } catch {
            XCTFail("应透传 URLError，得到 \(error)")
        }
        XCTAssertEqual(loader.callCount, 2, "最多重试一次")
    }

    func testTimedOutNotRetried() async {
        let req = URLRequest(url: URL(string: "https://example.com/v1/issue")!)
        let loader = ScriptedLoader([.failure(URLError(.timedOut))])
        await XCTAssertThrowsErrorAsync(
            try await RecapCredentialProvider.loadDataWithTransientRetry(req, load: loader.call))
        XCTAssertEqual(loader.callCount, 1, "15s 慢失败不得重试（关键路径不翻倍卡顿）")
    }

    func testOfflineNotRetried() async {
        let req = URLRequest(url: URL(string: "https://example.com/v1/issue")!)
        let loader = ScriptedLoader([.failure(URLError(.notConnectedToInternet))])
        await XCTAssertThrowsErrorAsync(
            try await RecapCredentialProvider.loadDataWithTransientRetry(req, load: loader.call))
        XCTAssertEqual(loader.callCount, 1, "持久离线重试无意义")
    }

    func testNonURLErrorNotRetried() async {
        let req = URLRequest(url: URL(string: "https://example.com/v1/issue")!)
        struct Boom: Error {}
        let loader = ScriptedLoader([.failure(Boom())])
        await XCTAssertThrowsErrorAsync(
            try await RecapCredentialProvider.loadDataWithTransientRetry(req, load: loader.call))
        XCTAssertEqual(loader.callCount, 1)
    }

    // MARK: - 分类指纹

    func testFastTransientClassification() {
        XCTAssertTrue(RecapCredentialProvider.isFastTransientNetworkError(URLError(.networkConnectionLost)))
        XCTAssertTrue(RecapCredentialProvider.isFastTransientNetworkError(URLError(.cannotConnectToHost)))
        XCTAssertTrue(RecapCredentialProvider.isFastTransientNetworkError(URLError(.cannotFindHost)))
        XCTAssertTrue(RecapCredentialProvider.isFastTransientNetworkError(URLError(.dnsLookupFailed)))
        XCTAssertFalse(RecapCredentialProvider.isFastTransientNetworkError(URLError(.timedOut)))
        XCTAssertFalse(RecapCredentialProvider.isFastTransientNetworkError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(RecapCredentialProvider.isFastTransientNetworkError(URLError(.cancelled)))
        struct Boom: Error {}
        XCTAssertFalse(RecapCredentialProvider.isFastTransientNetworkError(Boom()))
    }
}

/// XCTAssertThrowsError 的 async 版（std lib 无内置）。
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("预期抛错", file: file, line: line)
    } catch {
        // 预期路径
    }
}
