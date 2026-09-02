import Foundation

/// 会议转写语言（引擎选择 / LLM 输出语言跟随的依据）。
///
/// 分类由 `TranscriptLanguageClassifier` 从转写文本统计产出——**用户零操作**：
/// 录音结束/重转完成后自动判定，端侧与云端引擎据此自动适配，不新增任何设置项。
public enum MeetingLanguage: String, Codable, Sendable, CaseIterable {
    /// 中文为主（含中英混说：paraformer-realtime-v2 / zh-CN 双模块天然覆盖）。
    case zh
    /// 英文为主：端侧走 en-US 模块，云端走 fun-asr-realtime（多语言自动检测）。
    case en
    /// 中英大体各半（罕见）：引擎选择按 zh 处理（v2/双模块均支持混说）。
    case mixed

    /// 引擎选择口径：mixed 按 zh 走（paraformer-v2 / 双模块混说覆盖），无需额外分支。
    public var engineLanguage: MeetingLanguage {
        self == .en ? .en : .zh
    }
}

/// 转写语言分类器（纯函数，可单测）。
///
/// 统计字母字符中 CJK 与拉丁字母的占比，阈值语义以「引擎选择」为唯一目的：
/// - **en 只给英文为主**（拉丁 ≥ 85%）：必须上英文模型，否则必出音素乱码；
    /// - **zh 给中文过半**（CJK ≥ 50%）：zh 引擎（paraformer-v2 / 双模块）本就覆盖中英混说，
    ///   宽容带宽避免普通混说场次误判；
    /// - 其余（大体对半）→ mixed（引擎按 zh 走，仅供统计）。
/// **零新增 ML 依赖**——分类只需一次 O(n) 扫文本，毫秒级完成。
public enum TranscriptLanguageClassifier {

    /// 由分段文本判定整场语言。
    public static func classify(_ segments: [TranscriptSegment]) -> MeetingLanguage {
        classify(text: segments.map(\.text).joined())
    }

    /// 由拼接文本判定语言。
    ///
    /// 拉丁侧按「词」计：**单字符拉丁串不计入任何桶**（嗯/哦/啊等语气词与识别残迹的
    /// 罗马化——方言乱稿常整窗单字符碎片，旧口径把它全数当英文证据，是误判入口C）。
    /// 多字符英文词不受影响；数字/符号照旧两侧都不计。
    public static func classify(text: String) -> MeetingLanguage {
        var cjk = 0
        var latin = 0
        var run = 0
        func closeLatinRun() {
            if run >= 2 { latin += run }
            run = 0
        }
        for ch in text {
            if ch.isWhitespace || ch.isPunctuation {
                closeLatinRun()
            } else if isCJK(ch) {
                closeLatinRun()
                cjk += 1
            } else if ch.isLetter, ch.isASCII {
                run += 1
            } else {
                closeLatinRun()
            }
        }
        closeLatinRun()
        let total = cjk + latin
        guard total > 0 else { return .zh }
        let latinRatio = Double(latin) / Double(total)
        let cjkRatio = Double(cjk) / Double(total)
        if latinRatio >= 0.85 { return .en }
        if cjkRatio >= 0.5 { return .zh }
        return .mixed
    }

    /// 是否为 CJK 统一表意文字（含扩展区）。
    public static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,  // CJK 统一表意
             0x3400...0x4DBF,  // 扩展 A
             0x20000...0x2A6DF, // 扩展 B
             0xF900...0xFAFF:  // 兼容表意
            return true
        default:
            return false
        }
    }

    /// 文本是否含任一 CJK 字符（双转写器合并时的倾向性判据）。
    public static func containsCJK(_ text: String) -> Bool {
        text.contains(where: { isCJK($0) })
    }
}