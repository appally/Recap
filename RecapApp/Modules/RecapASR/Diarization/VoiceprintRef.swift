import Foundation
import FluidAudio

/// 人物目录引用（plan 064）：画廊身份的最小值快照（含未命名——命名率引导头要数它们）。
/// 独立文件的原因：UI 层（RecapUI/People）不应 import FluidAudio——其 `Speaker` 与
/// `RecapModels.Speaker` 同名冲突（`VoiceprintGallery.swift` 头注释的同一条纪律），
/// 本文件内不触碰 RecapModels 类型，无歧义。
public struct VoiceprintRef: Sendable, Hashable {
    public let voiceprintId: String
    public let name: String
    /// 画廊当前是否仍为默认名（发言人N 等）——命名状态以画廊为真相（最新纠错结果），
    /// 不看各场会议快照（旧场残留「发言人1」不代表现在未命名）。
    public let isUnnamed: Bool

    public init(voiceprintId: String, name: String, isUnnamed: Bool = false) {
        self.voiceprintId = voiceprintId
        self.name = name
        self.isUnnamed = isUnnamed
    }
}

extension VoiceprintGallery {

    /// 非「我」的全部画廊身份（plan 064 人物目录数据源；命名/未命名都带，由聚合层分流）。
    public func directoryRefs() -> [VoiceprintRef] {
        let meId = meVoiceprintId
        return snapshot().compactMap { sp in
            guard sp.id != meId else { return nil }
            return VoiceprintRef(
                voiceprintId: sp.id,
                name: sp.name,
                isUnnamed: VoiceprintRef.isUnnamedName(sp.name)
            )
        }
    }
}

extension VoiceprintRef {

    /// 与 `RecapModels.Speaker.isUnnamed` 同规则的画廊名判定（镜像实现，改动须双侧同步）。
    static func isUnnamedName(_ raw: String) -> Bool {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n == "转写" || n == "?" { return true }
        return n.hasPrefix("发言人")
    }
}
