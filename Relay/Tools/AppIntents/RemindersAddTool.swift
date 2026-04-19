import Foundation

/// Tool to add a reminder using EventKit.
public struct RemindersAddTool: RelayTool, Sendable {
 public var name: String { "reminders_add" }
 public var description: String { "Add a new reminder. Requires reminders permission." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "title": {
 "type": "string",
 "description": "Reminder title"
 },
 "notes": {
 "type": "string",
 "description": "Additional notes (optional)"
 },
 "due_date": {
 "type": "string",
 "description": "Due date/time in ISO8601 format (optional)"
 },
 "priority": {
 "type": "integer",
 "description": "Priority 0-9: 0=none, 1-4=low, 5=medium, 6-9=high (optional)"
 },
 "list": {
 "type": "string",
 "description": "Reminder list name (optional, uses default)"
 }
 },
 "required": ["title"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { false }
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let title = params["title"] as? String, !title.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'title' is required", isError: true)
 }

 let appIntents = context.services.appIntents

 if !(await appIntents().hasRemindersAccess()) {
 let granted = await appIntents().requestRemindersAccess()
 if !granted {
 return ToolResult(
 toolUseId: "",
 output: "Error: Reminders access denied. Please grant permission in Settings.",
 isError: true
 )
 }
 }

 var dueDate: Date?
 if let dueDateStr = params["due_date"] as? String {
 dueDate = ISO8601DateFormatter().date(from: dueDateStr)
 }

 let reminderInput = ReminderInput(
 title: title,
 notes: params["notes"] as? String,
 dueDate: dueDate,
 priority: params["priority"] as? Int,
 listName: params["list"] as? String
 )

 do {
 let result = try await appIntents().addReminder(reminderInput)

 var output = """
 Created reminder "\(result.title)"
 - List: \(result.listName)
 """
 if let dueDate = result.dueDate {
 let formatter = DateFormatter()
 formatter.dateStyle = .medium
 formatter.timeStyle = .short
 output += "\n- Due: \(formatter.string(from: dueDate))"
 }
 if let notes = result.notes {
 output += "\n- Notes: \(notes)"
 }
 output += "\n- ID: \(result.id)"

 return ToolResult(toolUseId: "", output: output)
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .reversible(domain: .reminders, operation: .create, summary: description)
 }
}
