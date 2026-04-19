import Foundation

/// Tool to delete a calendar event using EventKit.
public struct CalendarDeleteEventTool: RelayTool, Sendable {
 public var name: String { "calendar_delete_event" }
 public var description: String { "Delete a calendar event by its identifier. Requires calendar permission." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "event_id": {
 "type": "string",
 "description": "Identifier of the event to delete (from calendar_list_events)"
 }
 },
 "required": ["event_id"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { false }
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { true }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 guard let eventId = params["event_id"] as? String, !eventId.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'event_id' is required", isError: true)
 }

 let appIntents = context.services.appIntents

 if !(await appIntents().hasCalendarAccess()) {
 let granted = await appIntents().requestCalendarAccess()
 if !granted {
 return ToolResult(
 toolUseId: "",
 output: "Error: Calendar access denied. Please grant permission in Settings.",
 isError: true
 )
 }
 }

 do {
 try await appIntents().deleteCalendarEvent(id: eventId)
 return ToolResult(toolUseId: "", output: "Deleted event with ID: \(eventId)")
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]
 let eventId = (params["event_id"] as? String) ?? "(unknown)"
 return .destructive(
 domain: .calendar,
 operation: .delete,
 summary: description,
 targetDescription: "calendar event \(eventId)"
 )
 }
}
