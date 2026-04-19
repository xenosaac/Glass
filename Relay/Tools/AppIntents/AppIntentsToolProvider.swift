import Foundation

/// ToolProvider that bundles all AppIntent-related tools (Calendar, Reminders, Mail, SMS).
public struct AppIntentsToolProvider: ToolProvider, Sendable {
 public var providerName: String { "appintents" }
 public var source: ToolSource { .appIntents }

 public init() {}

 public func tools(for context: ToolCallContext) async -> [any RelayTool] {
 [
 CalendarCreateEventTool,
 CalendarListEventsTool,
 CalendarDeleteEventTool,
 RemindersAddTool,
 RemindersListTool,
 RemindersCompleteTool,
 EmailDraftTool,
 SMSSendTool,
 ]
 }
}
