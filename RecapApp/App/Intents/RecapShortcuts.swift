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
        // plan 049：零摩擦开录（短语必含 \(.applicationName)——AppShortcut 硬性要求）。
        // 注册后 Action Button 自动获得此入口（设置 → Action Button → 快捷指令）。
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "用 \(.applicationName) 开始录音",
                "在 \(.applicationName) 开始录音",
            ],
            shortTitle: "开始录音",
            systemImageName: "record.circle"
        )
    }
}
