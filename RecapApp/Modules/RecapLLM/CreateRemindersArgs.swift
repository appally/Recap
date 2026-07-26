import Foundation

/// `create_reminders` 参数解析（纯函数）。
///
/// **安全边界**：只接受已存在待办的 `action_item_ids`，不接受 task/owner/due 文本。
public enum CreateRemindersArgs {
    public static func parse(
        _ argumentsJSON: String,
        allowedIds: Set<UUID>
    ) -> [UUID] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let rawList = obj["action_item_ids"] as? [Any] ?? []
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for item in rawList {
            guard let s = item as? String,
                  let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)),
                  allowedIds.contains(id),
                  seen.insert(id).inserted
            else { continue }
            ids.append(id)
        }
        return ids
    }
}
