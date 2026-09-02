import Foundation
import FluidAudio
// 只引 RecapLog 单符号：避免 RecapModels.Speaker 与 FluidAudio 声纹 Speaker 歧义。
import enum RecapModels.RecapLog

// MARK: - 身份嵌入引擎抽象（声纹升级方案 Step 2）

/// 说话人嵌入引擎（声纹提取器）协议。
///
/// 聚类引擎（DiarizerManager 内部 WeSpeaker）与身份匹配引擎解耦：
/// 身份匹配只依赖本协议产出 L2 归一化嵌入向量（余弦比对），
/// 未来换 ERes2NetV2 只需新增一个实现。
public protocol SpeakerEmbeddingProvider: Sendable {
    /// 引擎名（写入画廊元数据，见 `VoiceprintMeta.engine`）。
    var engineName: String { get }
    /// 嵌入维度（CAM++ = 192；WeSpeaker = 256）。
    var embeddingDim: Int { get }
    /// 16kHz mono 样本 → L2 归一化嵌入。
    func embed(samples: [Float]) async throws -> [Float]
}

/// CAM++ 说话人嵌入引擎（FluidAudio `CampPlusEmbedder` 封装）。
///
/// - 7.2M 参数、中文 200k 说话人预训练（iic/speech_campplus_sv_zh-cn_16k-common）；
///   192-d 嵌入，CoreML↔torch 余弦 0.9997+（转换忠实，PR #652 实测同人 0.74 / 异人 0.35）。
/// - 模型 bundle 预置优先（`campplus-coreml` folder reference 随包 15.8MB，见
///   ``CampPlusEmbedderProvider/loadEmbedder()``）；资源缺失才回退 ModelHub 下载
///   （hf-mirror 镜像），落 Application Support/FluidAudio/Models（已被
///   ``BackupExclusion/excludeFluidAudioModels()`` 排除 iCloud 备份）。
/// - 推理走 ``CoreMLInferenceGate`` 串行门（与 SenseVoice / diarizer 互斥，#661）。
public actor CampPlusEmbedderProvider: SpeakerEmbeddingProvider {

    public static let shared = CampPlusEmbedderProvider()

    /// CAM++ 嵌入维度（非隔离静态：供 UI 层登记画廊用，免引 FluidAudio 类型）。
    public static let campPlusEmbeddingDim = CampPlusEmbedder.embeddingDim

    public let engineName = VoiceprintMeta.engineCampplus
    public let embeddingDim = CampPlusEmbedder.embeddingDim

    private var embedder: CampPlusEmbedder?
    private var preparing: Task<CampPlusEmbedder, Error>?
    /// 连续失败计数与熔断截止：国内网络下 ModelHub 下载必败（hf-mirror 断源），
    /// 不熔断则每场 diarize → match 都重新发起注定失败的网络尝试（分钟级超时拖慢会后链）。
    private var consecutiveFailures = 0
    private var backoffUntil: Date?

    private init() {}

    /// 懒加载（下载 + CoreML 编译）；失败可重试（退避窗过后自动放行）。
    public func ensureLoaded() async throws {
        _ = try await loadEmbedder()
    }

    /// 卸载 CoreML 模型（内存告警 / 离开 REVIEW / 切后台 / idle——与 diarizer 三件套同批）。
    /// 推理中调用安全：在飞 embed 的闭包持有 embedder 局部引用，跑完自然释放。
    /// 熔断状态（backoffUntil）不重置——与模型是否驻留内存无关。
    public func unload() {
        embedder = nil
    }

    public func embed(samples: [Float]) async throws -> [Float] {
        let embedder = try await loadEmbedder()
        guard !samples.isEmpty else {
            throw IdentityMatcherError.emptyAudioSegment
        }
        // CampPlusEmbedder.embed 是同步推理（preprocessor fp32/CPU + model fp16/ANE），
        // 放入串行门避免与其它 CoreML 推理并发触发 #661（embedder 为 actor，闭包内 await 进入）。
        return try await CoreMLInferenceGate.shared.exclusive {
            try await embedder.embed(audio: samples)
        }
    }

    // MARK: - 内部

    private func loadEmbedder() async throws -> CampPlusEmbedder {
        if let embedder { return embedder }
        if let until = backoffUntil, Date() < until {
            throw IdentityMatcherError.modelUnavailable("声纹模型此前加载失败，\(Int(until.timeIntervalSinceNow) / 60 + 1) 分钟后自动重试")
        }
        if let preparing {
            let e = try await preparing.value
            self.embedder = e
            self.preparing = nil
            return e
        }
        let task = Task<CampPlusEmbedder, Error> {
            // bundle 预置优先（照 FluidDiarizer.bundledModelsDirectory() 先例）：folder reference
            // 整目录随包，App Store 代码签名即完整性（零网络零校验）。2026-08-24 起 CAM++ 双模型
            // 15.8MB 随包——hf-mirror /resolve/ 308 回源后运行期下载国内不可达（详见 FluidDiarizer）。
            if let bundled = Bundle.main.url(forResource: "campplus-coreml", withExtension: nil),
               CampPlusModels.modelsExist(at: bundled) {
                return try CampPlusEmbedder(models: CampPlusModels.load(from: bundled))
            }
            // 回退运行期下载（资源被剥离/未来重构才走到）：052 P2-3 同款供应链加固——
            // 下载后按烤定 LFS 清单比特级复验，失配清缓存不留盘。
            let embedder = try await CampPlusEmbedder.load()
            guard FluidAudioBootstrap.verifyModelIntegrity(repo: .campPlus) else {
                FluidAudioBootstrap.removeCampPlusCache()
                throw IdentityMatcherError.modelUnavailable("声纹模型校验失败（下载可能损坏），已清除，请重试")
            }
            return embedder
        }
        preparing = task
        do {
            let e = try await task.value
            self.embedder = e
            self.preparing = nil
            consecutiveFailures = 0
            return e
        } catch {
            self.preparing = nil
            consecutiveFailures += 1
            if consecutiveFailures >= 2 {
                backoffUntil = Date().addingTimeInterval(15 * 60)
                consecutiveFailures = 0
                RecapLog.session.error("CampPlus 模型连续加载失败，进入 15 分钟退避（国内网络下载不可达场景）")
            }
            throw IdentityMatcherError.modelUnavailable(error.localizedDescription)
        }
    }
}

/// IdentityMatcher / 嵌入引擎错误（统一归因文案）。
public enum IdentityMatcherError: LocalizedError, Sendable {
    case emptyAudioSegment
    case modelUnavailable(String)
    case samplesRateMismatch

    public var errorDescription: String? {
        switch self {
        case .emptyAudioSegment:
            return "声纹片段为空，无法提取嵌入"
        case .modelUnavailable(let reason):
            return "声纹模型不可用：\(reason)"
        case .samplesRateMismatch:
            return "声纹提取需要 16kHz 采样率"
        }
    }
}