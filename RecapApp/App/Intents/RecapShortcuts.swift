import AppIntents

/// Recap 暴露给系统的快捷指令（出现在「快捷指令」App / Spotlight / Siri）。
/// 国行注意：Spotlight 索引 + 快捷指令 App 全可用；Siri 自然语言执行需 Apple Intelligence（国行待上线）。
struct RecapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMeetingIntent(),
            phrases: [
                "在 \(.applicationName) 打开会议",
                "用 \(.applicationName) 查会议",
            ],
            shortTitle: "打开会议",
            systemImageName: "doc.text.magnifyingglass"
        )
    }
}
