import Foundation

/// Tool to list reminders using EventKit.
public struct RemindersListTool: RelayTool, Sendable {
 public var name: String { "reminders_list" }
 public var description: String { "List reminders. Defaults to incomplete reminders only." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "include_completed": {
 "type": "boolean",
 "description": "Include completed reminders (default: false)"
 },
 "due_before": {
 "type": "string",
 "description": "Only show reminders due before this ISO8601 date (optional)"
 },
 "lists": {
 "type": "array",
 "items": { "type": "string" },
 "description": "Filter by list names (optional, default: all)"
 }
 }
 }
 """#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }
 /// tightly bound; ~80 chars/bullet × 8 bullets ≈ 700 chars.
 public var maxResultSizeChars: Int { 2_000 }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 let includeCompleted = params["include_completed"] as? Bool ?? false
 var dueBefore: Date?
 if let dateStr = params["due_before"] as? String {
 dueBefore = ISO8601DateFormatter().date(from: dateStr)
 }
 let lists = params["lists"] as? [String]

 let appIntents = context.services.appIntents

 if !(await appIntents().hasRemindersAccess()) {
 let granted = await appIntents().requestRemindersAccess()
 if !granted {
 return ToolResult(
 toolUseId: "",
 output: "Error: Reminders access denied.",
 isError: true
 )
 }
 }

 do {
 let reminders = try await appIntents().listReminders(
 includeCompleted: includeCompleted,
 dueBefore: dueBefore,
 lists: lists
 )

 if reminders.isEmpty {
 return ToolResult(toolUseId: "", output: "No reminders found.")
 }

 let formatter = DateFormatter()
 formatter.dateStyle = .short
 formatter.timeStyle = .short

 let lines = reminders.map { reminder in
 let status = reminder.isCompleted ? "[x]" : "[ ]"
 let due = reminder.dueDate.map { " (due: \(formatter.string(from: $0)))" } ?? ""
 return "\(status) \(reminder.title)\(due) [\(reminder.listName)]"
 }

 return ToolResult(
 toolUseId: "",
 output: "Found \(reminders.count) reminders:\n" + lines.joined(separator: "\n")
 )
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .reminders, operation: .read, summary: description)
 }
}
