import Foundation
import RecapModels

/// RecapPersistence 模块元信息。
public enum RecapPersistence {
    public static let moduleName = "RecapPersistence"
    public static let version = "0.7.0"
    /// 依赖校验：确保 RecapModels 已链接。
    public static var modelsVersion: String { RecapModels.version }
}
