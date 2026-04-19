import AppIntents
import Foundation

// MARK: - AskGlassIntent — opens the app and hands off a question or voice start

/// Open Glass and either start voice input or submit a typed question.
///
/// Because this intent runs from Siri/Shortcuts/Spotlight, we cannot talk to
/// the main app's agent runtime directly. We persist the intended action to
/// `LaunchActionStore` and set `openAppWhenRun = true`; `RelayAppShell`
/// consumes the action on cold launch or foreground resume.
public struct AskGlassIntent: AppIntent {
 public static var title: LocalizedStringResource = "Ask Glass"
 public static var description = IntentDescription(
 "Open Glass; if a question is provided, Glass answers it, otherwise voice input starts."
 )
 public static var openAppWhenRun: Bool = true

 @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to ask?"))
 public var query: String?

 public init() {}

 public func perform() async throws -> some IntentResult {
 if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
 LaunchActionStore.set(.askText(q))
 } else {
 LaunchActionStore.set(.startVoice)
 }
 return .result
 }
}

// MARK: - CreateEventIntent — thin wrapper around SystemIntentsService

/// Create a calendar event via Siri/Shortcuts. Runs entirely in the intent
/// process — does not open the app or invoke the agent.
public struct CreateEventIntent: AppIntent {
 public static var title: LocalizedStringResource = "Create Calendar Event"
 public static var description = IntentDescription("Add a new event to the default calendar.")

 @Parameter(title: "Title")
 public var eventTitle: String

 @Parameter(title: "Start")
 public var startDate: Date

 @Parameter(title: "End")
 public var endDate: Date

 public init() {}

 public func perform() async throws -> some IntentResult & ReturnsValue<String> {
 let service = SystemIntentsService
 let granted = await service.requestCalendarAccess
 guard granted else {
 return .result(value: "Calendar access denied. Grant access in Settings > Privacy > Calendar.")
 }
 do {
 let input = CalendarEventInput(title: eventTitle, startDate: startDate, endDate: endDate)
 let result = try await service.createCalendarEvent(input)
 let formatter = DateFormatter()
 formatter.dateStyle = .medium
 formatter.timeStyle = .short
 return .result(value: "Created: \(result.title) on \(formatter.string(from: result.startDate))")
 } catch {
 return .result(value: "Could not create event: \(error.localizedDescription)")
 }
 }
}

// MARK: - AddReminderIntent — thin wrapper around SystemIntentsService

/// Add a reminder via Siri/Shortcuts. Runs entirely in the intent process.
public struct AddReminderIntent: AppIntent {
 public static var title: LocalizedStringResource = "Add Reminder"
 public static var description = IntentDescription("Add a new reminder to the default list.")

 @Parameter(title: "Title")
 public var reminderTitle: String

 @Parameter(title: "Due Date")
 public var dueDate: Date?

 public init() {}

 public func perform() async throws -> some IntentResult & ReturnsValue<String> {
 let service = SystemIntentsService
 let granted = await service.requestRemindersAccess
 guard granted else {
 return .result(value: "Reminders access denied. Grant access in Settings > Privacy > Reminders.")
 }
 do {
 let input = ReminderInput(title: reminderTitle, dueDate: dueDate)
 let result = try await service.addReminder(input)
 return .result(value: "Added: \(result.title)")
 } catch {
 return .result(value: "Could not add reminder: \(error.localizedDescription)")
 }
 }
}
