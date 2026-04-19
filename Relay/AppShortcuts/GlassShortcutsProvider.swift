import AppIntents

/// Registers Glass's App Shortcuts with Siri, Shortcuts, and Spotlight.
/// iOS discovers this type automatically at app launch.
public struct GlassShortcutsProvider: AppShortcutsProvider {
 public static var appShortcuts: [AppShortcut] {
 AppShortcut(
 intent: AskGlassIntent(),
 phrases: ["Ask \(.applicationName)"],
 shortTitle: "Ask Glass",
 systemImageName: "bubble.left.and.text.bubble.right"
 )
 AppShortcut(
 intent: CreateEventIntent(),
 phrases: ["Create event with \(.applicationName)"],
 shortTitle: "Create Event",
 systemImageName: "calendar.badge.plus"
 )
 AppShortcut(
 intent: AddReminderIntent(),
 phrases: ["Remind me with \(.applicationName)"],
 shortTitle: "Add Reminder",
 systemImageName: "checklist"
 )
 }
}
