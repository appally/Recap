import Foundation
import Security

/// Keychain 凭证管理：存 API Key / 火山凭证等。
/// 用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：
///   首次解锁后可用 / 不随 iCloud 备份同步 / 设备绑定。
/// 绝不进 UserDefaults / 日志 / 源码。
///
/// 放在 RecapModels：ASR 与 LLM 共用，避免 RecapASR ↔ RecapLLM 互相依赖。
public enum KeychainStore {

    /// 写入或更新（account 为唯一键，如 LLMPresets.deepSeekKeychainAccount）。
    @discardableResult
    public static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// 读取；不存在返回 nil。
    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除。
    @discardableResult
    public static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
