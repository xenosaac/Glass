import Foundation

/// JSONL conversation log — one file per session, one `RelayMessage` JSON per line.
///
/// implements a `.jsonl` session persistence pattern.
/// Each `append(_:)` writes a single JSON line (no pretty printing).
/// `loadAll` is fault-tolerant: lines that fail to decode are silently skipped.
public actor SessionStore {

 public let sessionId: String
 private let baseDir: URL
 private let fileURL: URL
 private let schemaURL: URL
 private let encoder = JSONEncoder()
 private let decoder = JSONDecoder()
 private let contract = StorageRegistry.contract(for: .sessionTranscript)

 public init(sessionId: String, baseDir: URL = AppPaths.sessions) {
 self.sessionId = sessionId
 self.baseDir = baseDir
 self.fileURL = baseDir.appendingPathComponent("\(sessionId).jsonl")
 self.schemaURL = baseDir.appendingPathComponent("schema.json")
 }

 // MARK: - Write

 /// Append a single message as a JSON line to the session file.
 public func append(_ message: RelayMessage) throws {
 try ensureBaseDirectory()
 try StorageContractIO.ensureCompanionHeader(for: contract, at: schemaURL)

 let data = try encoder.encode(message)
 guard var line = String(data: data, encoding: .utf8) else { return }
 line += "\n"

 if FileManager.default.fileExists(atPath: fileURL.path) {
 let handle = try FileHandle(forWritingTo: fileURL)
 defer { handle.closeFile() }
 handle.seekToEndOfFile()
 if let lineData = line.data(using: .utf8) {
 handle.write(lineData)
 }
 } else {
 try line.data(using: .utf8)?.write(to: fileURL, options: .atomic)
 }
 }

 // MARK: - Read

 /// Load all messages from the session file. Skips lines that fail to decode.
 public func loadAll() throws -> [RelayMessage] {
 try ensureBaseDirectory()
 try StorageContractIO.ensureCompanionHeader(for: contract, at: schemaURL)
 guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

 let content = try String(contentsOf: fileURL, encoding: .utf8)
 let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

 return lines.compactMap { line in
 guard let data = line.data(using: .utf8) else { return nil }
 return try? decoder.decode(RelayMessage.self, from: data)
 }
 }

 // MARK: - Lifecycle

 /// Delete the session file.
 public func clear() throws {
 let fm = FileManager.default
 if fm.fileExists(atPath: fileURL.path) {
 try fm.removeItem(at: fileURL)
 }
 }

 /// Whether the session file exists on disk.
 public var fileExists: Bool {
 FileManager.default.fileExists(atPath: fileURL.path)
 }

 /// Number of lines (messages) in the session file. Returns 0 if file doesn't exist.
 public var messageCount: Int {
 guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
 return content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
 }

 private func ensureBaseDirectory() throws {
 if !FileManager.default.fileExists(atPath: baseDir.path) {
 try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
 }
 }
}
