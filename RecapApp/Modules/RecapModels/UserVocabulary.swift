import Foundation

/// 用户全局「常用词」表（plan 050 Wave A）：人名/公司/术语等专有名词，
/// 注入端侧 SA contextualStrings 与润色层【本场专名提示】。
///
/// 边界：只进**本机**消费（端侧引擎 / 本地组装的润色 user prompt），
/// 不进任何云请求——跨会议数据上云的口径见 plans/050 否决段（Wave C 若立项需重审）。
/// UserDefaults 持久（与 UserProfile 同级）；上限 100 词、每词 ≤15 字符——
/// 对齐阿里热词条目约束，为将来 Wave C（vocabulary_id）保留形状。
public enum UserVocabulary {

    static let storageKey = "recap.user.vocabulary"
    public static let maxWords = 100
    /// 阿里热词条目「非 ASCII 词 ≤15 字符」同款约束。
    public static let maxWordLength = 15

    /// 词表（去重保序）。
    public static var words: [String] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
            var seen = Set<String>()
            return raw.filter { seen.insert($0).inserted }
        }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= maxWordLength }
                .filter { seen.insert($0).inserted }
            UserDefaults.standard.set(Array(cleaned.prefix(maxWords)), forKey: storageKey)
        }
    }

    /// 添加一个词；已存在或超限返回 false。
    @discardableResult
    public static func add(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxWordLength else { return false }
        var current = words
        guard !current.contains(trimmed) else { return false }
        guard current.count < maxWords else { return false }
        current.append(trimmed)
        words = current
        return true
    }

    @discardableResult
    public static func remove(_ word: String) -> Bool {
        var current = words
        guard let idx = current.firstIndex(of: word) else { return false }
        current.remove(at: idx)
        words = current
        return true
    }
}
