import Foundation

/// Tool to create a calendar event using EventKit.
public struct CalendarCreateEventTool: RelayTool, Sendable {
 public var name: String { "calendar_create_event" }
 public var description: String { "Create a new calendar event. Requires calendar permission." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "title": {
 "type": "string",
 "description": "Event title"
 },
 "start_date": {
 "type": "string",
 "description": "Start date/time in ISO8601 format (e.g., 2026-04-10T14:00:00)"
 },
 "end_date": {
 "type": "string",
 "description": "End date/time in ISO8601 format"
 },
 "location": {
 "type": "string",
 "description": "Event location (optional)"
 },
 "notes": {
 "type": "string",
 "description": "Event notes/description (optional)"
 },
 "all_day": {
 "type": "boolean",
 "description": "Whether this is an all-day event (default: false)"
 },
 "calendar": {
 "type": "string",
 "description": "Calendar name to add event to (optional, uses default)"
 }
 },
 "required": ["title", "start_date", "end_date"]
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

 let formatter = ISO8601DateFormatter()
 formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

 guard let startStr = params["start_date"] as? String else {
 return ToolResult(toolUseId: "", output: "Error: 'start_date' is required", isError: true)
 }
 guard let startDate = formatter.date(from: startStr) ?? ISO8601DateFormatter().date(from: startStr) else {
 return ToolResult(toolUseId: "", output: "Error: 'start_date' must be valid ISO8601", isError: true)
 }

 guard let endStr = params["end_date"] as? String else {
 return ToolResult(toolUseId: "", output: "Error: 'end_date' is required", isError: true)
 }
 guard let endDate = formatter.date(from: endStr) ?? ISO8601DateFormatter().date(from: endStr) else {
 return ToolResult(toolUseId: "", output: "Error: 'end_date' must be valid ISO8601", isError: true)
 }

 let appIntents = context.services.appIntents

 // Check and request permission if needed
 if !(await appIntents.hasCalendarAccess) {
 let granted = await appIntents.requestCalendarAccess
 if !granted {
 return ToolResult(
 toolUseId: "",
 output: "Error: Calendar access denied. Please grant permission in Settings.",
 isError: true
 )
 }
 }

 let eventInput = CalendarEventInput(
 title: title,
 startDate: startDate,
 endDate: endDate,
 location: params["location"] as? String,
 notes: params["notes"] as? String,
 isAllDay: params["all_day"] as? Bool ?? false,
 calendarName: params["calendar"] as? String
 )

 do {
 let result = try await appIntents.createCalendarEvent(eventInput)
 let displayFormatter = DateFormatter()
 displayFormatter.dateStyle = .medium
 displayFormatter.timeStyle = .short

 var output = """
 Created event "\(result.title)"
 - Calendar: \(result.calendarName)
 - Start: \(displayFormatter.string(from: result.startDate))
 - End: \(displayFormatter.string(from: result.endDate))
 """
 if let location = result.location {
 output += "\n- Location: \(location)"
 }
 output += "\n- ID: \(result.id)"

 return ToolResult(toolUseId: "", output: output)
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .reversible(domain: .calendar, operation: .create, summary: description)
 }
}
