import XCTest
@testable import RecapLLM

/// `OpenAICompatibleProvider` 对第三方 OpenAI 兼容中转（token.toai.pro）的真网络冒烟。
///
/// 真网络用例需注入 `TOAI_API_KEY`（xcodebuild 侧用 `TEST_RUNNER_TOAI_API_KEY` 前缀透传），
/// 缺省自动跳过，CI / 日常单测不受影响。覆盖生产代码全链路：
/// URL 拼接（parseBaseURL）→ MacPaw 请求 → SSE 流式 → 中转 keepalive 空 delta 容忍 → 首 token 看门狗。
/// API Key 只从环境变量读，绝不写入源码 / 落盘。
final class OpenAICompatibleRelayIntegrationTests: XCTestCase {

    private var relayAPIKey: String? {
        ProcessInfo.processInfo.environment["TOAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - parseBaseURL（纯单测，无网络）

    /// 中转类端点两种写法（带/不带 /v1）须归一到同一 host+path，
    /// 否则设置页随便一种写法都会 404。
    func testParseBaseURLRelayVariants() {
        let bare = OpenAICompatibleProvider.parseBaseURL("https://token.toai.pro")
        XCTAssertEqual(bare.host, "token.toai.pro")
        XCTAssertEqual(bare.basePath, "/v1")

        let explicit = OpenAICompatibleProvider.parseBaseURL("https://token.toai.pro/v1")
        XCTAssertEqual(explicit.host, "token.toai.pro")
        XCTAssertEqual(explicit.basePath, "/v1")

        let trailingSlash = OpenAICompatibleProvider.parseBaseURL("https://token.toai.pro/v1/")
        XCTAssertEqual(trailingSlash.basePath, "/v1")
    }

    /// 子路径网关（百炼兼容模式）不能丢路径——旧 bug 的回归锚点。
    func testParseBaseURLSubpathGateway() {
        let parsed = OpenAICompatibleProvider.parseBaseURL("https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(parsed.host, "dashscope.aliyuncs.com")
        XCTAssertEqual(parsed.basePath, "/compatible-mode/v1")
    }

    // MARK: - 真网络（env-gated）

    func testStreamTextAgainstRelay() async throws {
        guard let key = relayAPIKey else {
            throw XCTSkip("需 TOAI_API_KEY（xcodebuild 经 TEST_RUNNER_TOAI_API_KEY 注入）")
        }
        let env = ProcessInfo.processInfo.environment
        let provider = OpenAICompatibleProvider(
            id: "custom",
            apiKey: key,
            baseURL: env["TOAI_BASE_URL"] ?? "https://token.toai.pro/v1",
            defaultModel: env["TOAI_MODEL"] ?? "auto/fast",
            // 中转路由期间只发 keepalive 空 delta，预算放宽到 30s 防 thinking 档误杀。
            firstTokenTimeoutSeconds: 30
        )

        var result = ""
        let stream = provider.streamText(
            system: "你是冒烟测试助手，回答务必简短。",
            messages: [AskChatTurn(role: .user, content: "只回复两个字：收到")],
            model: nil,
            temperature: 0
        )
        for try await delta in stream {
            result += delta
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "流式结果为空（keepalive 未出正文的迹象）")
    }
}
