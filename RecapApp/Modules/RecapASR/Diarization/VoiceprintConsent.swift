import Foundation

/// 声纹（生物识别）处理的用户同意状态。
///
/// 声纹 = PIPL §28 敏感个人信息，须「单独同意」（独立 UI，不得与麦克风/隐私政策捆绑）。
/// 默认未同意；首次「标记我」时由独立同意页（``VoiceprintConsentSheet``）取得。
/// 撤回 = 删除全部声纹（``VoiceprintGallery/clearAll()``）并重置本标志 → 下次重新弹窗。
public enum VoiceprintConsent {
    private static let key = "recap.voiceprint.consentGranted"

    public static var granted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 撤回同意（配合 VoiceprintGallery.clearAll()：删数据 + 重置标志）。
    public static func reset() {
        UserDefaults.standard.set(false, forKey: key)
    }
}
