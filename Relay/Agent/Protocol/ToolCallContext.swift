import Foundation

/// Dependency-injection bag passed to every tool call.
///
/// Tools fetch the iOS subsystems they need via `services` (a `ServiceLocator`),
/// rather than receiving every subsystem directly. This keeps the context lean
/// and lets each tool declare its dependencies explicitly.
public struct ToolCallContext: Sendable {
 /// Read-only snapshot of the conversation history at the start of this call.
 public let messages: [RelayMessage]

 /// Session metadata (id, started-at, persona).
 public let session: AgentSession

 /// Host-owned approval boundary for destructive or sensitive tool actions.
 public let approvalBroker: any ApprovalBroker

 /// Streaming progress callback for long-running tools.
 public let progress: @Sendable (ToolProgress) -> Void

 /// Service locator — fetch the iOS subsystems needed for this call.
 public let services: any ServiceLocator

 public init(
 messages: [RelayMessage],
 session: AgentSession,
 approvalBroker: any ApprovalBroker,
 progress: @escaping @Sendable (ToolProgress) -> Void,
 services: any ServiceLocator
 ) {
 self.messages = messages
 self.session = session
 self.approvalBroker = approvalBroker
 self.progress = progress
 self.services = services
 }
}

/// Session metadata propagated through every turn.
public struct AgentSession: Sendable {
 public let id: String
 public let startedAt: Date
 public let personaId: String?
 /// Session's default working directory. Relative file paths resolve against this.
 public let workspaceURL: URL?

 public init(id: String, startedAt: Date, personaId: String? = nil, workspaceURL: URL? = nil) {
 self.id = id
 self.startedAt = startedAt
 self.personaId = personaId
 self.workspaceURL = workspaceURL
 }
}

/// Streaming progress event from a tool execution.
public struct ToolProgress: Sendable {
 public let toolUseId: String
 public let message: String
 public let percent: Double?

 public init(toolUseId: String, message: String, percent: Double? = nil) {
 self.toolUseId = toolUseId
 self.message = message
 self.percent = percent
 }
}

/// Service locator. Tools fetch the subsystems they need.
/// Each method is intentionally narrow so tools declare their dependencies.
public protocol ServiceLocator: Sendable {
 func fileProvider() -> any FileProviderService
 func appIntents() -> any AppIntentsService
 func mcpClient(server: String) -> (any MCPClientService)?
 func gmail() -> any GmailService
 /// Claude-Code-style memory store for the session. Nil if the host
 /// hasn't wired one up (legacy smoke tests, unit fixtures).
 func memoryStore() -> MemoryStore?
}

public extension ServiceLocator {
 /// Default: no memory available. Concrete locators override to return
 /// the session's shared MemoryStore.
 func memoryStore() -> MemoryStore? { nil }
}

// MARK: - Forward-declared service protocols ( modules implement these)

public protocol FileProviderService: Sendable {
 /// Check if a path is within an authorized folder.
 func isAuthorized(path: String) async -> Bool

 /// Get all authorized folder URLs.
 func authorizedFolders() async -> [URL]

 /// Read file contents. Throws if path not authorized or file doesn't exist.
 func readFile(at path: String) async throws -> Data

 /// Write data to file. Creates parent directories if needed.
 func writeFile(at path: String, data: Data, createIntermediates: Bool) async throws

 /// List directory contents.
 func listDirectory(at path: String, recursive: Bool, includeHidden: Bool) async throws -> [FileEntry]

 /// Search file contents via Core Spotlight.
 func searchFiles(query: String, inFolder: String?, limit: Int) async throws -> [FileSearchResult]

 /// Add a new authorized folder (stores security-scoped bookmark).
 func addAuthorization(url: URL) async throws
}

/// A file or directory entry from listDirectory.
public struct FileEntry: Sendable {
 public let name: String
 public let path: String
 public let isDirectory: Bool
 public let size: Int64
 public let modifiedAt: Date

 public init(name: String, path: String, isDirectory: Bool, size: Int64, modifiedAt: Date) {
 self.name = name
 self.path = path
 self.isDirectory = isDirectory
 self.size = size
 self.modifiedAt = modifiedAt
 }
}

/// A search result from Core Spotlight.
public struct FileSearchResult: Sendable {
 public let path: String
 public let displayName: String

 public init(path: String, displayName: String) {
 self.path = path
 self.displayName = displayName
 }
}

/// Default no-op implementation so NoOpFileProvider keeps compiling.
public extension FileProviderService {
 func isAuthorized(path: String) async -> Bool { false }
 func authorizedFolders() async -> [URL] { [] }
 func readFile(at path: String) async throws -> Data { throw FileProviderError.notAuthorized(path) }
 func writeFile(at path: String, data: Data, createIntermediates: Bool) async throws { throw FileProviderError.notAuthorized(path) }
 func listDirectory(at path: String, recursive: Bool, includeHidden: Bool) async throws -> [FileEntry] { throw FileProviderError.notAuthorized(path) }
 func searchFiles(query: String, inFolder: String?, limit: Int) async throws -> [FileSearchResult] { [] }
 func addAuthorization(url: URL) async throws {}
}

public enum FileProviderError: Error, LocalizedError {
 case notAuthorized(String)
 case fileNotFound(String)
 case notDirectory(String)
 case writeFailed(String)

 public var errorDescription: String? {
 switch self {
 case .notAuthorized(let path): return "Path not authorized: \(path)"
 case .fileNotFound(let path): return "File not found: \(path)"
 case .notDirectory(let path): return "Not a directory: \(path)"
 case .writeFailed(let path): return "Write failed: \(path)"
 }
 }
}
/// Service for iOS system integrations (Calendar, Reminders).
/// Mail/SMS are handled via UI presentation (MessageUI).
public protocol AppIntentsService: Sendable {
 // MARK: - Permission Status

 /// Check if calendar access has been granted.
 func hasCalendarAccess() async -> Bool

 /// Check if reminders access has been granted.
 func hasRemindersAccess() async -> Bool

 /// Request full calendar access (iOS 17+).
 func requestCalendarAccess() async -> Bool

 /// Request full reminders access (iOS 17+).
 func requestRemindersAccess() async -> Bool

 // MARK: - Calendar Operations

 /// Create a calendar event.
 func createCalendarEvent(_ event: CalendarEventInput) async throws -> CalendarEventResult

 /// List calendar events in a date range.
 func listCalendarEvents(from startDate: Date, to endDate: Date, calendars: [String]?) async throws -> [CalendarEventResult]

 // MARK: - Reminders Operations

 /// Add a reminder.
 func addReminder(_ reminder: ReminderInput) async throws -> ReminderResult

 /// List reminders.
 func listReminders(includeCompleted: Bool, dueBefore: Date?, lists: [String]?) async throws -> [ReminderResult]

 /// Delete a calendar event by ID.
 func deleteCalendarEvent(id: String) async throws

 /// Complete a reminder by ID.
 func completeReminder(id: String) async throws
}

// MARK: - AppIntents Data Types

public struct CalendarEventInput: Sendable {
 public let title: String
 public let startDate: Date
 public let endDate: Date
 public let location: String?
 public let notes: String?
 public let isAllDay: Bool
 public let calendarName: String?

 public init(title: String, startDate: Date, endDate: Date, location: String? = nil,
 notes: String? = nil, isAllDay: Bool = false, calendarName: String? = nil) {
 self.title = title
 self.startDate = startDate
 self.endDate = endDate
 self.location = location
 self.notes = notes
 self.isAllDay = isAllDay
 self.calendarName = calendarName
 }
}

public struct CalendarEventResult: Sendable {
 public let id: String
 public let title: String
 public let startDate: Date
 public let endDate: Date
 public let location: String?
 public let calendarName: String
 public let isAllDay: Bool

 public init(id: String, title: String, startDate: Date, endDate: Date,
 location: String?, calendarName: String, isAllDay: Bool) {
 self.id = id
 self.title = title
 self.startDate = startDate
 self.endDate = endDate
 self.location = location
 self.calendarName = calendarName
 self.isAllDay = isAllDay
 }
}

public struct ReminderInput: Sendable {
 public let title: String
 public let notes: String?
 public let dueDate: Date?
 public let priority: Int?
 public let listName: String?

 public init(title: String, notes: String? = nil, dueDate: Date? = nil,
 priority: Int? = nil, listName: String? = nil) {
 self.title = title
 self.notes = notes
 self.dueDate = dueDate
 self.priority = priority
 self.listName = listName
 }
}

public struct ReminderResult: Sendable {
 public let id: String
 public let title: String
 public let notes: String?
 public let dueDate: Date?
 public let isCompleted: Bool
 public let listName: String

 public init(id: String, title: String, notes: String?, dueDate: Date?,
 isCompleted: Bool, listName: String) {
 self.id = id
 self.title = title
 self.notes = notes
 self.dueDate = dueDate
 self.isCompleted = isCompleted
 self.listName = listName
 }
}

public enum AppIntentsError: Error, LocalizedError {
 case notAvailable
 case permissionDenied(String)
 case calendarNotFound(String)
 case reminderListNotFound(String)
 case saveFailed(String)

 public var errorDescription: String? {
 switch self {
 case .notAvailable: return "AppIntents service not available"
 case .permissionDenied(let type): return "\(type) permission denied"
 case .calendarNotFound(let name): return "Calendar not found: \(name)"
 case .reminderListNotFound(let name): return "Reminder list not found: \(name)"
 case .saveFailed(let reason): return "Save failed: \(reason)"
 }
 }
}

/// Default no-op implementation for NoOpAppIntents.
public extension AppIntentsService {
 func hasCalendarAccess() async -> Bool { false }
 func hasRemindersAccess() async -> Bool { false }
 func requestCalendarAccess() async -> Bool { false }
 func requestRemindersAccess() async -> Bool { false }
 func createCalendarEvent(_ event: CalendarEventInput) async throws -> CalendarEventResult {
 throw AppIntentsError.notAvailable
 }
 func listCalendarEvents(from: Date, to: Date, calendars: [String]?) async throws -> [CalendarEventResult] { [] }
 func addReminder(_ reminder: ReminderInput) async throws -> ReminderResult {
 throw AppIntentsError.notAvailable
 }
 func listReminders(includeCompleted: Bool, dueBefore: Date?, lists: [String]?) async throws -> [ReminderResult] { [] }
 func deleteCalendarEvent(id: String) async throws { throw AppIntentsError.notAvailable }
 func completeReminder(id: String) async throws { throw AppIntentsError.notAvailable }
}

/// MCP client service for communicating with MCP servers.
public protocol MCPClientService: Sendable {
 /// List tools available on this server.
 func listTools(forceRefresh: Bool) async throws -> [MCPToolDefinition]

 /// Call a tool on this server.
 func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolCallResult
}

/// Default no-op extension so NoOpMCPClient compiles.
public extension MCPClientService {
 func listTools(forceRefresh: Bool) async throws -> [MCPToolDefinition] { [] }
 func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolCallResult {
 MCPToolCallResult(content: [MCPContentBlock(type: "text", text: "MCP not configured")])
 }
}

// MARK: - Gmail service

/// Personal-workflow Gmail provider. Single account, Keychain-backed tokens.
/// Intended to be consumed by Gmail tools (`gmail_search`, etc.) and by the
/// Settings UI for connect/disconnect. Tools should call `isSignedIn` and
/// degrade gracefully when the user has not authenticated.
public protocol GmailService: Sendable {
 /// Whether the OAuth Client ID is configured at build time.
 func isConfigured() async -> Bool

 /// Whether there's a persisted refresh token for this install.
 func isSignedIn() async -> Bool

 /// Email address of the signed-in account, if known.
 func currentUserEmail() async -> String?

 /// Start OAuth PKCE flow. Must be invokable from the main thread.
 func signIn() async throws

 /// Clear persisted credentials (Keychain).
 func signOut() async

 /// Search messages with Gmail query syntax. Returns lightweight summaries.
 func search(query: String, maxResults: Int) async throws -> [GmailMessageSummary]

 /// Fetch a single message with parsed headers and best-effort text/plain body.
 func messageFull(id: String) async throws -> GmailMessage

 /// Fetch an entire thread.
 func threadFull(id: String) async throws -> GmailThread

 /// Create a draft reply to an existing message. Preserves threading
 /// (In-Reply-To, References, Subject: Re:). Returns the new draft's ID.
 func createDraftReply(sourceMessageID: String, body: String) async throws -> String

 /// Send a new message or reply. If `inReplyToMessageID` is provided, the
 /// send includes RFC 2822 threading headers + Gmail `threadId`.
 func sendMessage(to: String, subject: String, body: String, inReplyToMessageID: String?) async throws -> String
}

public extension GmailService {
 func isConfigured() async -> Bool { false }
 func isSignedIn() async -> Bool { false }
 func currentUserEmail() async -> String? { nil }
 func signIn() async throws { throw GmailError.notConfigured }
 func signOut() async {}
 func search(query: String, maxResults: Int) async throws -> [GmailMessageSummary] { throw GmailError.notSignedIn }
 func messageFull(id: String) async throws -> GmailMessage { throw GmailError.notSignedIn }
 func threadFull(id: String) async throws -> GmailThread { throw GmailError.notSignedIn }
 func createDraftReply(sourceMessageID: String, body: String) async throws -> String { throw GmailError.notSignedIn }
 func sendMessage(to: String, subject: String, body: String, inReplyToMessageID: String?) async throws -> String { throw GmailError.notSignedIn }
}
