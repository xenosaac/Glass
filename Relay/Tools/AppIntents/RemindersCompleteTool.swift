import Foundation

/// Tool to mark a reminder as completed using EventKit.
public struct RemindersCompleteTool: RelayTool, Sendable {
 public var name: String { "reminders_complete" }
 public var description: String { "Mark a reminder as completed. Requires reminders permission." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "reminder_id": {
 "type": "string",
 "description": "Identifier of the reminder to mark complete (from reminders_list)"
 }
 },
 "required": ["reminder_id"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { false }
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let reminderId = params["reminder_id"] as? String, !reminderId.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'reminder_id' is required", isError: true)
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

 do {
 try await appIntents().completeReminder(id: reminderId)
 return ToolResult(toolUseId: "", output: "Marked reminder complete (ID: \(reminderId))")
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .reversible(domain: .reminders, operation: .update, summary: description)
 }
}
