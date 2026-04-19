import Foundation

/// Tracks which folders have been indexed into the Memory Palace.
///
/// State machine per folder path:
/// `.notIndexed` → `beginIndexing` → `.indexing` → `finishIndexing` → `.indexed`
/// `.indexing` → `failIndexing` → `.notIndexed`
/// `.indexed` (stale) → `beginIndexing` → `.indexing` → ...
/// `.indexing` → `beginIndexing` → returns `false` (rejects concurrent)
///
/// Persisted to `Application Support/Relay/folderIndex.json` on every state transition.
public actor FolderIndexRegistry {

 public enum IndexState: Codable, Equatable, Sendable {
 case notIndexed
 case indexing(startedAt: Date)
 case indexed(indexedAt: Date, documentCount: Int)
 }

 struct Entry: Codable, Sendable {
 let path: String
 var state: IndexState
 }

 private var entries: [String: Entry] = [:]
 private let fileURL: URL
 private let encoder: JSONEncoder
 private let decoder: JSONDecoder
 private let contract = StorageRegistry.contract(for: .folderIndex)

 public init(fileURL: URL = AppPaths.folderIndex) {
 self.fileURL = fileURL
 let encoder = JSONEncoder()
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 self.encoder = encoder
 self.decoder = JSONDecoder()
 }

 /// Read-only accessor for consumers that want to poll current state of
 /// a known path (e.g., ChatView's workspace chip). Returns nil if we've
 /// never seen this path before.
 public func state(for path: String) -> IndexState? {
 entries[path]?.state
 }

 /// Returns true and transitions to `.indexing` only if folder is `.notIndexed` or stale `.indexed`.
 /// Returns false if already `.indexing` or recently `.indexed`.
 public func beginIndexing(_ path: String, staleAfter: TimeInterval = 86400) -> Bool {
 let entry = entries[path]

 switch entry?.state {
 case .indexing:
 return false // Already in-flight
 case .indexed(let indexedAt, _):
 if Date().timeIntervalSince(indexedAt) < staleAfter {
 return false // Recently indexed, not stale
 }
 case .notIndexed, .none:
 break // Proceed
 }

 entries[path] = Entry(path: path, state: .indexing(startedAt: Date()))
 save
 return true
 }

 /// Transition from `.indexing` to `.indexed`.
 public func finishIndexing(_ path: String, count: Int) {
 entries[path] = Entry(path: path, state: .indexed(indexedAt: Date(), documentCount: count))
 save
 }

 /// Transition from `.indexing` back to `.notIndexed` (on failure).
 public func failIndexing(_ path: String) {
 entries[path] = Entry(path: path, state: .notIndexed)
 save
 }

 // MARK: - Persistence

 public func load() {
 guard let data = try? Data(contentsOf: fileURL) else {
 entries = [:]
 return
 }
 if let envelope = try? decoder.decode(VersionedStoreEnvelope<[Entry]>.self, from: data) {
 guard envelope.header.isCompatible(with: contract) else {
 entries = [:]
 try? FileManager.default.removeItem(at: fileURL)
 return
 }
 entries = Dictionary(envelope.payload.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
 return
 }

 if let legacy = try? decoder.decode([Entry].self, from: data) {
 entries = Dictionary(legacy.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
 save
 return
 }

 entries = [:]
 try? FileManager.default.removeItem(at: fileURL)
 }

 private func save() {
 try? StorageContractIO.ensureParentDirectory(for: fileURL)
 let array = Array(entries.values).sorted() { $0.path < $1.path }
 let envelope = VersionedStoreEnvelope(header: contract.schemaHeader, payload: array)
 guard let data = try? encoder.encode(envelope) else { return }
 try? data.write(to: fileURL, options: .atomic)
 }
}
