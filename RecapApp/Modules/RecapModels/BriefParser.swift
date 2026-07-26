import Foundation

/// Phase A：无 LLM 的底稿启发式解析（粘贴文本 / 关联上场）。
public enum BriefParser {

    /// 从粘贴或文件抽出的纯文本解析议程 / 遗留。
    public static func parseText(_ text: String, role: BriefRole = .agenda) -> BriefParseResult {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return BriefParseResult() }

        switch role {
        case .priorMinutes, .linkedMeeting:
            return parsePriorMinutes(normalized)
        case .roster:
            return parseRoster(normalized)
        case .notes, .proposal, .agenda:
            return parseAgendaHeavy(normalized, preferOpenItems: role == .notes)
        }
    }

    /// 从上一场 Recap 会议抽取连续层（未完成待办 + 未决问题）。
    public static func parseLinkedMeeting(_ meeting: Meeting) -> BriefParseResult {
        var openItems: [OpenItem] = []
        var entityHints: [String] = []

        for item in meeting.actionItems where item.status != .done {
            openItems.append(OpenItem(
                text: item.task,
                ownerHint: item.owner,
                dueHint: item.dueText,
                fromMeetingId: meeting.id,
                resolution: "open"
            ))
            if let owner = item.owner { entityHints.append(owner) }
        }

        if let summary = meeting.outputs
            .first(where: { $0.kind == .summary })?
            .summaryPayload {
            for q in summary.openQuestions {
                let cleaned = q.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                openItems.append(OpenItem(
                    text: cleaned,
                    fromMeetingId: meeting.id,
                    resolution: "open"
                ))
            }
        }

        for speaker in meeting.speakers {
            entityHints.append(speaker.name)
        }

        // 去重
        var seen = Set<String>()
        openItems = openItems.filter {
            let key = $0.text.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        return BriefParseResult(
            agenda: [],
            openItems: openItems,
            entityHints: uniqueHints(entityHints),
            suggestedTitle: nil
        )
    }

    /// 根据文件名/首页关键词猜测角色。
    public static func guessRole(fileName: String?, textHead: String) -> BriefRole {
        let blob = ((fileName ?? "") + " " + textHead.prefix(200)).lowercased()
        if blob.contains("纪要") || blob.contains("minutes") || blob.contains("遗留") {
            return .priorMinutes
        }
        if blob.contains("议案") || blob.contains("汇报") || blob.contains("proposal") {
            return .proposal
        }
        if blob.contains("名单") || blob.contains("签到") || blob.contains("roster") {
            return .roster
        }
        if blob.contains("议程") || blob.contains("agenda") || blob.contains("议题") {
            return .agenda
        }
        return .agenda
    }

    // MARK: - Private

    private static func parseAgendaHeavy(_ text: String, preferOpenItems: Bool) -> BriefParseResult {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var agenda: [AgendaItem] = []
        var openItems: [OpenItem] = []
        var hints: [String] = []
        var suggestedTitle: String?
        var order = 1
        var inOpenSection = preferOpenItems

        for line in lines {
            if isTitleLine(line), suggestedTitle == nil {
                suggestedTitle = stripDecorators(line)
                continue
            }
            if isOpenSectionHeader(line) {
                inOpenSection = true
                continue
            }
            if isAgendaSectionHeader(line) {
                inOpenSection = false
                continue
            }

            if inOpenSection || looksLikeOpenItem(line) {
                let cleaned = stripListPrefix(line)
                guard cleaned.count >= 2 else { continue }
                let (task, owner) = splitOwner(cleaned)
                openItems.append(OpenItem(text: task, ownerHint: owner))
                if let owner { hints.append(owner) }
                continue
            }

            if let item = parseAgendaLine(line, order: order) {
                agenda.append(item)
                if let owner = item.ownerHint { hints.append(owner) }
                order += 1
            }
        }

        // 若完全没识别出条目，把非空行当议程（最多 12 条）
        if agenda.isEmpty && openItems.isEmpty {
            for line in lines.prefix(12) where !isTitleLine(line) && !isSectionHeader(line) {
                let cleaned = stripListPrefix(line)
                guard cleaned.count >= 2 else { continue }
                agenda.append(AgendaItem(order: order, title: cleaned))
                order += 1
            }
        }

        return BriefParseResult(
            agenda: agenda,
            openItems: openItems,
            entityHints: uniqueHints(hints),
            suggestedTitle: suggestedTitle
        )
    }

    private static func parsePriorMinutes(_ text: String) -> BriefParseResult {
        var result = parseAgendaHeavy(text, preferOpenItems: true)
        // 上场纪要以遗留为主：若只抽出议程、无遗留，把议程条目降级为遗留提示
        if result.openItems.isEmpty && !result.agenda.isEmpty {
            result.openItems = result.agenda.map {
                OpenItem(text: $0.title, ownerHint: $0.ownerHint)
            }
            result.agenda = []
        }
        return result
    }

    private static func parseRoster(_ text: String) -> BriefParseResult {
        let tokens = text
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；/\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 8 }
        return BriefParseResult(entityHints: uniqueHints(tokens))
    }

    private static func parseAgendaLine(_ line: String, order: Int) -> AgendaItem? {
        let stripped = stripListPrefix(line)
        guard stripped.count >= 2, stripped.count <= 80 else { return nil }
        // 过滤明显的段落正文
        if stripped.count > 40 && !lineHasListPrefix(line) { return nil }

        let (title, owner) = splitOwner(stripped)
        var duration: Int?
        if let match = title.range(of: #"(\d+)\s*[分钟分']"#, options: .regularExpression) {
            let num = title[match].filter(\.isNumber)
            duration = Int(num).map { $0 * 60 }
        }

        return AgendaItem(
            order: order,
            title: title,
            ownerHint: owner,
            durationHintSeconds: duration
        )
    }

    private static func lineHasListPrefix(_ line: String) -> Bool {
        let pattern = #"^(\d+[\.\)、．]|[（(]\d+[）)]|[•·\-–—]|第[一二三四五六七八九十\d]+)"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func stripListPrefix(_ line: String) -> String {
        var s = line
        let patterns = [
            #"^\d+[\.\)、．]\s*"#,
            #"^[（(]\d+[）)]\s*"#,
            #"^[•·\-–—]\s*"#,
            #"^第[一二三四五六七八九十\d]+[项条款议题]\s*"#,
            #"^\[\s*[xX ]?\s*\]\s*"#,
            #"^□\s*"#,
            #"^☐\s*"#,
        ]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression) {
                s.removeSubrange(r)
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func splitOwner(_ text: String) -> (String, String?) {
        // 「预算评审（阿成）」或「预算评审 - 阿成」或「预算评审 汇报人:阿成」
        if let r = text.range(of: #"[(（]([^)）]{1,12})[)）]\s*$"#, options: .regularExpression) {
            let owner = String(text[r])
                .trimmingCharacters(in: CharacterSet(charactersIn: "()（）"))
            let title = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if title.count >= 2 { return (title, owner) }
        }
        if let r = text.range(of: #"\s[-–—]\s*(.{1,12})$"#, options: .regularExpression) {
            let owner = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
            let title = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if title.count >= 2, owner.count <= 8 { return (title, owner) }
        }
        return (text, nil)
    }

    private static func isTitleLine(_ line: String) -> Bool {
        let s = stripDecorators(line)
        guard s.count >= 4, s.count <= 24 else { return false }
        let keywords = ["会议", "周会", "办公会", "评审", "董事会", "访谈", "同步"]
        return keywords.contains(where: { s.contains($0) }) && !lineHasListPrefix(line)
    }

    private static func stripDecorators(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "#* "))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isOpenSectionHeader(_ line: String) -> Bool {
        let s = line.lowercased()
        return s.contains("遗留") || s.contains("待办") || s.contains("未决")
            || s.contains("跟进") || s.contains("action") || s.contains("open item")
    }

    private static func isAgendaSectionHeader(_ line: String) -> Bool {
        let s = line.lowercased()
        return s.contains("议程") || s.contains("议题") || s.contains("agenda")
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        isOpenSectionHeader(line) || isAgendaSectionHeader(line)
    }

    private static func looksLikeOpenItem(_ line: String) -> Bool {
        line.hasPrefix("[") || line.hasPrefix("☐") || line.hasPrefix("□")
            || line.contains("待跟进") || line.contains("需闭环")
    }

    private static func uniqueHints(_ hints: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for h in hints {
            let t = h.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, !seen.contains(t) else { continue }
            seen.insert(t)
            result.append(t)
        }
        return Array(result.prefix(40))
    }
}
