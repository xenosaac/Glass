import Foundation
import EventKit

/// Actor that wraps EventKit for Calendar and Reminders operations.
/// Thread-safe and works with Swift concurrency.
public actor SystemIntentsService: AppIntentsService {
 private let eventStore: EKEventStore

 public init() {
 self.eventStore = EKEventStore()
 }

 // MARK: - Permission Status

 public func hasCalendarAccess() async -> Bool {
 EKEventStore.authorizationStatus(for: .event) == .fullAccess
 }

 public func hasRemindersAccess() async -> Bool {
 EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
 }

 public func requestCalendarAccess() async -> Bool {
 do {
 return try await eventStore.requestFullAccessToEvents()
 } catch {
 return false
 }
 }

 public func requestRemindersAccess() async -> Bool {
 do {
 return try await eventStore.requestFullAccessToReminders()
 } catch {
 return false
 }
 }

 // MARK: - Calendar Operations

 public func createCalendarEvent(_ input: CalendarEventInput) async throws -> CalendarEventResult {
 guard await hasCalendarAccess() else {
 throw AppIntentsError.permissionDenied("Calendar")
 }

 let event = EKEvent(eventStore: eventStore)
 event.title = input.title
 event.startDate = input.startDate
 event.endDate = input.endDate
 event.location = input.location
 event.notes = input.notes
 event.isAllDay = input.isAllDay

 // Find calendar by name or use default
 if let calendarName = input.calendarName {
 guard let calendar = eventStore.calendars(for: .event)
 .first(where: { $0.title == calendarName }) else {
 throw AppIntentsError.calendarNotFound(calendarName)
 }
 event.calendar = calendar
 } else {
 event.calendar = eventStore.defaultCalendarForNewEvents
 }

 do {
 try eventStore.save(event, span: .thisEvent)
 } catch {
 throw AppIntentsError.saveFailed(error.localizedDescription)
 }

 return CalendarEventResult(
 id: event.eventIdentifier,
 title: event.title,
 startDate: event.startDate,
 endDate: event.endDate,
 location: event.location,
 calendarName: event.calendar.title,
 isAllDay: event.isAllDay
 )
 }

 public func listCalendarEvents(
 from startDate: Date,
 to endDate: Date,
 calendars: [String]?
 ) async throws -> [CalendarEventResult] {
 guard await hasCalendarAccess() else {
 throw AppIntentsError.permissionDenied("Calendar")
 }

 // Filter calendars by name if specified
 let targetCalendars: [EKCalendar]?
 if let names = calendars {
 let filtered = eventStore.calendars(for: .event)
 .filter { names.contains($0.title) }
 targetCalendars = filtered.isEmpty ? nil : filtered
 } else {
 targetCalendars = nil
 }

 let predicate = eventStore.predicateForEvents(
 withStart: startDate,
 end: endDate,
 calendars: targetCalendars
 )

 let events = eventStore.events(matching: predicate)

 return events.map { event in
 CalendarEventResult(
 id: event.eventIdentifier,
 title: event.title,
 startDate: event.startDate,
 endDate: event.endDate,
 location: event.location,
 calendarName: event.calendar.title,
 isAllDay: event.isAllDay
 )
 }
 }

 // MARK: - Reminders Operations

 public func addReminder(_ input: ReminderInput) async throws -> ReminderResult {
 guard await hasRemindersAccess() else {
 throw AppIntentsError.permissionDenied("Reminders")
 }

 let reminder = EKReminder(eventStore: eventStore)
 reminder.title = input.title
 reminder.notes = input.notes
 reminder.priority = input.priority ?? 0

 if let dueDate = input.dueDate {
 reminder.dueDateComponents = Calendar.current.dateComponents(
 [.year, .month, .day, .hour, .minute],
 from: dueDate
 )
 }

 // Find list by name or use default
 if let listName = input.listName {
 guard let list = eventStore.calendars(for: .reminder)
 .first(where: { $0.title == listName }) else {
 throw AppIntentsError.reminderListNotFound(listName)
 }
 reminder.calendar = list
 } else {
 reminder.calendar = eventStore.defaultCalendarForNewReminders()
 }

 do {
 try eventStore.save(reminder, commit: true)
 } catch {
 throw AppIntentsError.saveFailed(error.localizedDescription)
 }

 return ReminderResult(
 id: reminder.calendarItemIdentifier,
 title: reminder.title ?? "",
 notes: reminder.notes,
 dueDate: reminder.dueDateComponents?.date,
 isCompleted: reminder.isCompleted,
 listName: reminder.calendar.title
 )
 }

 public func listReminders(
 includeCompleted: Bool,
 dueBefore: Date?,
 lists: [String]?
 ) async throws -> [ReminderResult] {
 guard await hasRemindersAccess() else {
 throw AppIntentsError.permissionDenied("Reminders")
 }

 // Filter lists by name if specified
 let targetLists: [EKCalendar]?
 if let names = lists {
 targetLists = eventStore.calendars(for: .reminder)
 .filter { names.contains($0.title) }
 } else {
 targetLists = nil
 }

 let predicate: NSPredicate
 if includeCompleted {
 predicate = eventStore.predicateForReminders(in: targetLists)
 } else {
 predicate = eventStore.predicateForIncompleteReminders(
 withDueDateStarting: nil,
 ending: dueBefore,
 calendars: targetLists
 )
 }

 // fetchReminders is callback-based, wrap in continuation
 let reminders = await withCheckedContinuation { continuation in
 eventStore.fetchReminders(matching: predicate) { reminders in
 continuation.resume(returning: reminders ?? [])
 }
 }

 return reminders.map { reminder in
 ReminderResult(
 id: reminder.calendarItemIdentifier,
 title: reminder.title ?? "",
 notes: reminder.notes,
 dueDate: reminder.dueDateComponents?.date,
 isCompleted: reminder.isCompleted,
 listName: reminder.calendar.title
 )
 }
 }

 public func deleteCalendarEvent(id: String) async throws {
 guard await hasCalendarAccess() else {
 throw AppIntentsError.permissionDenied("Calendar")
 }
 guard let event = eventStore.event(withIdentifier: id) else {
 throw AppIntentsError.calendarNotFound(id)
 }
 do {
 try eventStore.remove(event, span: .thisEvent, commit: true)
 } catch {
 throw AppIntentsError.saveFailed(error.localizedDescription)
 }
 }

 public func completeReminder(id: String) async throws {
 guard await hasRemindersAccess() else {
 throw AppIntentsError.permissionDenied("Reminders")
 }
 guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
 throw AppIntentsError.reminderListNotFound(id)
 }
 reminder.isCompleted = true
 do {
 try eventStore.save(reminder, commit: true)
 } catch {
 throw AppIntentsError.saveFailed(error.localizedDescription)
 }
 }
}
