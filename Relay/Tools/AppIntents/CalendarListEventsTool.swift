import Foundation

/// Tool to list upcoming calendar events using EventKit.
public struct CalendarListEventsTool: RelayTool, Sendable {
 public var name: String { "calendar_list_events" }
 public var description: String { "List upcoming calendar events within a date range. Defaults to next 7 days." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "start_date": {
 "type": "string",
 "description": "Start of range in ISO8601 (default: now)"
 },
 "end_date": {
 "type": "string",
 "description": "End of range in ISO8601 (default: 7 days from now)"
 },
 "calendars": {
 "type": "array",
 "items": { "type": "string" },
 "description": "Filter by calendar names (optional, default: all)"
 }
 }
 }
 """#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }
 /// tightly bound — at ~80 chars/bullet × 8 bullets
 /// the rendered output fits in ~700 chars. Anything larger means the
 /// user has many recurring events; the persistor wrapper is fine.
 public var maxResultSizeChars: Int { 2_000 }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]

 let formatter = ISO8601DateFormatter()
 let startDate: Date
 let endDate: Date

 if let startStr = params["start_date"] as? String,
 let parsed = formatter.date(from: startStr) {
 startDate = parsed
 } else {
 startDate = Date()
 }

 if let endStr = params["end_date"] as? String,
 let parsed = formatter.date(from: endStr) {
 endDate = parsed
 } else {
 endDate = Calendar.current.date(byAdding: .day, value: 7, to: startDate) ?? startDate
 }

 let calendars = params["calendars"] as? [String]

 let appIntents = context.services.appIntents

 if !(await appIntents().hasCalendarAccess()) {
 let granted = await appIntents().requestCalendarAccess()
 if !granted {
 return ToolResult(
 toolUseId: "",
 output: "Error: Calendar access denied.",
 isError: true
 )
 }
 }

 do {
 let events = try await appIntents().listCalendarEvents(
 from: startDate,
 to: endDate,
 calendars: calendars
 )

 if events.isEmpty {
 return ToolResult(toolUseId: "", output: "No events found in the specified range.")
 }

 let displayFormatter = DateFormatter()
 displayFormatter.dateStyle = .short
 displayFormatter.timeStyle = .short

 // 2 : group recurring events by title.
 // EventKit expands recurrences into per-occurrence instances —
 // a daily standup over a 7-day query becomes 7 rows. First
 // occurrence wins for the rendered date/time/location (events
 // are already sorted by startDate); a "(N more this period)"
 // suffix conveys the remaining count without listing each one.
 var uniqueByTitle: [(title: String, first: CalendarEventResult)] = []
 var seenTitles = Set<String>()
 var totalByTitle: [String: Int] = [:]
 for event in events {
 totalByTitle[event.title, default: 0] += 1
 if seenTitles.insert(event.title).inserted {
 uniqueByTitle.append((event.title, event))
 }
 }

 // 3 : cap displayed unique-title events
 // at 8. Calendars with many distinct titles (e.g., 67 unique
 // over 7 days) would otherwise produce a wall-of-text bubble
 // AND pollute conversation history (subsequent turns lose the
 // model in the noise → cloud-confusion → identity-violation
 // fallback). Events are already sorted by startDate ascending,
 // so the first 8 are the next-upcoming items by time.
 let cap = 8
 let displayed = Array(uniqueByTitle.prefix(cap))
 let truncatedCount = uniqueByTitle.count - displayed.count

 var lines: [String] = displayed.map { (title, event) in
 let time = event.isAllDay ? "All day" : displayFormatter.string(from: event.startDate)
 let location = event.location.map { " @ \($0)" } ?? ""
 let totalForTitle = totalByTitle[title, default: 1]
 let suffix = totalForTitle > 1 ? " (\(totalForTitle - 1) more this period)" : ""
 return "- \(time): \(title)\(location) [\(event.calendarName)]\(suffix)"
 }
 if truncatedCount > 0 {
 let plural = truncatedCount == 1 ? "event" : "events"
 lines.append("- + \(truncatedCount) more \(plural) this period")
 }

 let header: String
 if events.count == uniqueByTitle.count {
 let plural = events.count == 1 ? "event" : "events"
 header = "Found \(events.count) \(plural):"
 } else {
 header = "Found \(events.count) events (\(uniqueByTitle.count) unique):"
 }

 return ToolResult(
 toolUseId: "",
 output: header + "\n" + lines.joined(separator: "\n")
 )
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .calendar, operation: .read, summary: description)
 }
}
