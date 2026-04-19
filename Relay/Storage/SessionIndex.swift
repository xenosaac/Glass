import Foundation

/// Metadata for a single chat session.
///
/// Persisted in `sessions/index.json`. Contains display info (title, timestamps)
/// and workspace context (default folder for file operations).
public struct SessionMetadata: Codable, Identifiable, Sendable {
 public let id: String
 public var title: String
 public var workspaceURL: URL?
 public let createdAt: Date
 public var lastMessageAt: Date
 public var messageCount: Int
 /// Conversation turns indexed up to this message count.
 public var lastIndexedMessageCount: Int?
 /// Preference extraction scanned up to this message count.
 public var preferencesScannedToCount: Int?

 public init(
 id: String = UUID().uuidString,
 title: String = "New Chat",
 workspaceURL: URL? = nil,
 createdAt: Date = Date(),
 lastMessageAt: Date = Date(),
 messageCount: Int = 0
 ) {
 self.id = id
 self.title = title
 self.workspaceURL = workspaceURL
 self.createdAt = createdAt
 self.lastMessageAt = lastMessageAt
 self.messageCount = messageCount
 }
}

/// Manages the index of all chat sessions.
///
/// Sessions are stored as individual JSONL files by `SessionStore`.
/// This actor maintains a separate index file (`sessions/index.json`)
/// with metadata for quick enumeration without parsing all session files.
public actor SessionIndex {

 private let baseDir: URL
 private let indexURL: URL
 private var sessions: [String: SessionMetadata] = [:]
 private let encoder: JSONEncoder
 private let decoder: JSONDecoder
 private let contract = StorageRegistry.contract(for: .sessionIndex)

 public init(baseDir: URL = AppPaths.sessions) {
 self.baseDir = baseDir
 self.indexURL = baseDir.appendingPathComponent("index.json")
 self.encoder = JSONEncoder()
 self.encoder.dateEncodingStrategy = .iso8601
 self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 self.decoder = JSONDecoder()
 self.decoder.dateDecodingStrategy = .iso8601
 }

 // MARK: - Load

 /// Load the session index from disk.
 public func load() async throws {
 try ensureBaseDirectory()

 guard FileManager.default.fileExists(atPath: indexURL.path) else {
 sessions = [:]
 return
 }

 let data = try Data(contentsOf: indexURL)
 var shouldRewrite = false
 let list: [SessionMetadata]

 if let envelope = try? decoder.decode(VersionedStoreEnvelope<[SessionMetadata]>.self, from: data) {
 if envelope.header.isCompatible(with: contract) {
 list = envelope.payload
 shouldRewrite = envelope.header.version != contract.version
 } else {
 _ = try? StorageContractIO.archiveItemIfExists(at: indexURL, storeID: contract.id)
 sessions = [:]
 return
 }
 } else if let legacy = try? decoder.decode([SessionMetadata].self, from: data) {
 list = legacy
 shouldRewrite = true
 } else {
 _ = try? StorageContractIO.archiveItemIfExists(at: indexURL, storeID: contract.id)
 sessions = [:]
 return
 }

 sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
 if repairTranscriptDerivedFieldsForAllSessions() {
 shouldRewrite = true
 }
 if shouldRewrite {
 try save()
 }
 }

 // MARK: - Save

 private func save() throws {
 try ensureBaseDirectory()

 let list = Array(sessions.values).sorted() { $0.lastMessageAt > $1.lastMessageAt }
 let envelope = VersionedStoreEnvelope(header: contract.schemaHeader, payload: list)
 let data = try encoder.encode(envelope)
 try data.write(to: indexURL, options: .atomic)
 }

 // MARK: - CRUD

 /// Get all sessions, sorted by most recent first.
 public func all() -> [SessionMetadata] {
 Array(sessions.values).sorted() { $0.lastMessageAt > $1.lastMessageAt }
 }

 /// Get a single session by ID.
 public func get(_ id: String) -> SessionMetadata? {
 sessions[id]
 }

 /// Create a new session with optional workspace.
 @discardableResult
 public func create(workspace: URL? = nil) throws -> SessionMetadata {
 let session = SessionMetadata(workspaceURL: workspace)
 sessions[session.id] = session
 try save()
 return session
 }

 /// Update session metadata.
 public func update(_ session: SessionMetadata) throws {
 sessions[session.id] = session
 try save()
 }

 /// Update session after a new message is added.
 public func recordMessage(sessionId: String, firstUserText: String? = nil) throws {
 guard var session = sessions[sessionId] else { return }

 session.messageCount += 1
 session.lastMessageAt = Date()

 // Use first user message as title (truncated)
 if session.title == "New Chat", let text = firstUserText {
 let truncated = String(text.prefix(50))
 session.title = truncated.count < text.count ? truncated + "..." : truncated
 }

 sessions[sessionId] = session
 try save()
 }

 /// Delete a session and its JSONL file.
 public func delete(id: String) throws {
 sessions.removeValue(forKey: id)
 try save()

 // Also delete the session file
 let sessionFile = baseDir.appendingPathComponent("\(id).jsonl")
 if FileManager.default.fileExists(atPath: sessionFile.path) {
 try FileManager.default.removeItem(at: sessionFile)
 }
 }

 /// Atomic clear-all: empties the in-memory dict, rewrites `index.json` with
 /// an empty list, and removes every `.jsonl` transcript file in the
 /// sessions directory. Shell callers must follow up with their own
 /// `sessions = []` / `currentSessionId = nil` refresh; the actor only owns
 /// storage.
 public func deleteAll() throws {
 sessions.removeAll()
 try save()
 guard let files = try? FileManager.default.contentsOfDirectory(
 at: baseDir, includingPropertiesForKeys: nil
 ) else { return }
 for file in files where file.pathExtension == "jsonl" {
 try? FileManager.default.removeItem(at: file)
 }
 }

 /// Check if any sessions exist.
 public var isEmpty: Bool {
 sessions.isEmpty
 }

 /// Total session count.
 public var count: Int {
 sessions.count
 }

 private func ensureBaseDirectory() throws {
 if !FileManager.default.fileExists(atPath: baseDir.path) {
 try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
 }
 }

 @discardableResult
 private func repairTranscriptDerivedFieldsForAllSessions() -> Bool {
 var changed = false
 for key in sessions.keys.sorted() {
 guard var metadata = sessions[key] else { continue }
 let transcriptURL = baseDir.appendingPathComponent("\(key).jsonl")
 guard FileManager.default.fileExists(atPath: transcriptURL.path) else { continue }

 if let content = try? String(contentsOf: transcriptURL, encoding: .utf8) {
 let actualCount = content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
 if actualCount != metadata.messageCount {
 metadata.messageCount = actualCount
 changed = true
 }
 }

 if let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptURL.path),
 let modifiedAt = attrs[.modificationDate] as? Date,
 modifiedAt != metadata.lastMessageAt {
 metadata.lastMessageAt = modifiedAt
 changed = true
 }

 sessions[key] = metadata
 }
 return changed
 }
}

// MARK: - Date Grouping

extension SessionMetadata {
 /// Group label for session list display.
 public var dateGroup: SessionDateGroup {
 let calendar = Calendar.current
 let now = Date()

 if calendar.isDateInToday(lastMessageAt) {
 return .today
 } else if calendar.isDateInYesterday(lastMessageAt) {
 return .yesterday
 } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
 lastMessageAt > weekAgo {
 return .thisWeek
 } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
 lastMessageAt > monthAgo {
 return .thisMonth
 } else {
 return .older
 }
 }
}

public enum SessionDateGroup: String, CaseIterable {
 case today = "Today"
 case yesterday = "Yesterday"
 case thisWeek = "This Week"
 case thisMonth = "This Month"
 case older = "Older"
}
