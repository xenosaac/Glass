import XCTest
@testable import Relay

/// 2 — `CalendarListEventsTool` now collapses
/// EventKit's per-instance expansion of recurring events into one row
/// per title, with a "(N more this period)" suffix when the underlying
/// total > 1.
final class CalendarListEventsToolTests: XCTestCase {

 // MARK: - Fakes

 private struct FakeAppIntents: AppIntentsService {
 let events: [CalendarEventResult]
 let access: Bool

 func hasCalendarAccess() async -> Bool { access }
 func requestCalendarAccess() async -> Bool { access }
 func listCalendarEvents(
 from startDate: Date,
 to endDate: Date,
 calendars: [String]?
 ) async throws -> [CalendarEventResult] {
 events
 }
 }

 private static func makeContext(events: [CalendarEventResult]) -> ToolCallContext {
 ToolCallContext(
 messages: [],
 session: AgentSession(id: "calendar-test", startedAt: Date),
 approvalBroker: AlwaysAllowBroker,
 progress: { _ in },
 services: DefaultServiceLocator(
 appIntents: FakeAppIntents(events: events, access: true)
 )
 )
 }

 private struct AlwaysAllowBroker: ApprovalBroker, Sendable {
 func evaluate(
 tool: any RelayTool,
 input: ToolInput,
 context: ToolCallContext
 ) async -> ApprovalDecision {
 .allow
 }
 }

 private static func makeEvent(
 title: String,
 offsetMinutes: Int,
 location: String? = nil,
 calendar: String = "Work"
 ) -> CalendarEventResult {
 let start = Date().addingTimeInterval(TimeInterval(offsetMinutes * 60))
 return CalendarEventResult(
 id: UUID.uuidString,
 title: title,
 startDate: start,
 endDate: start.addingTimeInterval(30 * 60),
 location: location,
 calendarName: calendar,
 isAllDay: false
 )
 }

 // MARK: - Tests

 func test_calendarListEvents_groupsRecurringByTitle() async throws {
 // 5 standups + 1 lunch + 1 design review = 7 events, 3 unique.
 let events: [CalendarEventResult] = [
 Self.makeEvent(title: "Standup", offsetMinutes: 60, location: "Zoom"),
 Self.makeEvent(title: "Standup", offsetMinutes: 60 + 24 * 60, location: "Zoom"),
 Self.makeEvent(title: "Standup", offsetMinutes: 60 + 48 * 60, location: "Zoom"),
 Self.makeEvent(title: "Standup", offsetMinutes: 60 + 72 * 60, location: "Zoom"),
 Self.makeEvent(title: "Standup", offsetMinutes: 60 + 96 * 60, location: "Zoom"),
 Self.makeEvent(title: "Lunch with Sarah", offsetMinutes: 240, calendar: "Personal"),
 Self.makeEvent(title: "Design review", offsetMinutes: 300)
 ]

 let tool = CalendarListEventsTool
 let context = Self.makeContext(events: events)
 let result = try await tool.call(input: ToolInput(json: Data("{}".utf8)), context: context)

 XCTAssertFalse(result.isError, "tool should succeed")
 let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init())
 XCTAssertEqual(lines.first, "Found 7 events (3 unique):", "header should reflect total + unique count")
 let bullets = lines.dropFirst.filter { $0.hasPrefix("- ") }
 XCTAssertEqual(bullets.count, 3, "5 standups should collapse to 1 row")

 // Standup row carries "(4 more this period)" — 5 standups, first wins, 4 more.
 let standupRow = bullets.first { $0.contains("Standup") }
 XCTAssertNotNil(standupRow)
 XCTAssertTrue(
 standupRow?.contains("(4 more this period)") == true,
 "standup row should annotate 4 more occurrences, got: \(standupRow ?? "nil")"
 )

 // Single-occurrence rows have NO suffix.
 let lunchRow = bullets.first { $0.contains("Lunch with Sarah") }
 XCTAssertNotNil(lunchRow)
 XCTAssertFalse(
 lunchRow?.contains("more this period") == true,
 "non-recurring rows should have no suffix"
 )
 }

 func test_calendarListEvents_singleOccurrenceUnchanged() async throws {
 let events: [CalendarEventResult] = [
 Self.makeEvent(title: "Standup", offsetMinutes: 60),
 Self.makeEvent(title: "Lunch", offsetMinutes: 240, calendar: "Personal"),
 Self.makeEvent(title: "Design review", offsetMinutes: 300)
 ]

 let tool = CalendarListEventsTool
 let context = Self.makeContext(events: events)
 let result = try await tool.call(input: ToolInput(json: Data("{}".utf8)), context: context)

 XCTAssertFalse(result.isError)
 let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init())
 XCTAssertEqual(lines.first, "Found 3 events:", "header should NOT include (unique) when no grouping happened")
 let bullets = lines.dropFirst.filter { $0.hasPrefix("- ") }
 XCTAssertEqual(bullets.count, 3)
 XCTAssertFalse(
 bullets.contains(where: { $0.contains("more this period") }),
 "no suffix should appear when every event is unique"
 )
 }

 func test_calendarListEvents_emptyResultUnchanged() async throws {
 let tool = CalendarListEventsTool
 let context = Self.makeContext(events: [])
 let result = try await tool.call(input: ToolInput(json: Data("{}".utf8)), context: context)

 XCTAssertFalse(result.isError)
 XCTAssertEqual(result.output, "No events found in the specified range.")
 }

 // MARK: - cap tests

 func test_calendarListEvents_capsAtEightUniqueTitles() async throws {
 // 12 distinct titles → cap at 8, expect "+ 4 more events this period" line.
 let events: [CalendarEventResult] = (0..<12).map { i in
 Self.makeEvent(title: "Event \(i)", offsetMinutes: 60 + i * 30)
 }

 let tool = CalendarListEventsTool
 let context = Self.makeContext(events: events)
 let result = try await tool.call(input: ToolInput(json: Data("{}".utf8)), context: context)

 XCTAssertFalse(result.isError)
 let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init())
 XCTAssertEqual(lines.first, "Found 12 events:", "all events unique → no (unique) suffix in header")

 let bulletLines = lines.dropFirst.filter { $0.hasPrefix("- ") }
 XCTAssertEqual(bulletLines.count, 9, "8 displayed events + 1 truncation line")

 let truncationLine = bulletLines.last
 XCTAssertEqual(truncationLine, "- + 4 more events this period")

 // First 8 displayed are the earliest by time (Event 0 .. Event 7).
 XCTAssertTrue(bulletLines.first?.contains("Event 0") == true)
 XCTAssertFalse(
 bulletLines.dropLast.contains(where: { $0.contains("Event 8") }),
 "9th event must NOT be displayed; only counted in the truncation suffix"
 )
 }

 func test_calendarListEvents_underCap_noTruncationLine() async throws {
 // 5 distinct titles — well under the 8-event cap.
 let events: [CalendarEventResult] = (0..<5).map { i in
 Self.makeEvent(title: "Event \(i)", offsetMinutes: 60 + i * 30)
 }

 let tool = CalendarListEventsTool
 let context = Self.makeContext(events: events)
 let result = try await tool.call(input: ToolInput(json: Data("{}".utf8)), context: context)

 XCTAssertFalse(result.isError)
 let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init())
 let bulletLines = lines.dropFirst.filter { $0.hasPrefix("- ") }
 XCTAssertEqual(bulletLines.count, 5, "no truncation line when under cap")
 XCTAssertFalse(
 bulletLines.contains(where: { $0.contains("more events this period") }),
 "no truncation suffix when count <= cap"
 )
 }
}
