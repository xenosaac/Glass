import Foundation

/// Session-scoped persistent store for `Attachment` values.
///
/// JSON-file-per-attachment under
/// `AppPaths.attachments(forSessionId:)`. Dedups on `contentHash`
/// so repeated ingestion of the same file is a no-op. An internal
/// inverted index is rebuilt lazily on first `retrieve(...)` call
/// after any mutation, so retrieval is cheap across repeated queries
/// in the same turn.
///
/// Explicitly out of scope this phase: cross-session sharing,
/// attachment cleanup on session delete, background re-index, any
/// UI surface.
public actor AttachmentStore {

 // MARK: - State

 public let sessionId: String
 private let root: URL
 private let schemaURL: URL
 private let fileManager: FileManager
 private let encoder: JSONEncoder
 private let decoder: JSONDecoder
 private let contract = StorageRegistry.contract(for: .attachment)

 /// In-memory cache. Populated lazily on first `all` / `retrieve(...)`
 /// call via `load`. Source of truth for membership + content.
 private var cache: [UUID: Attachment] = [:]
 private var loaded = false

 /// Lazy inverted index: `term -> [(attachmentId, chunkIndex)]`.
 /// Rebuilt on first `retrieve(...)` after any cache mutation.
 private var invertedIndex: [String: [ChunkRef]] = [:]
 private var indexDirty = true

 private struct ChunkRef: Sendable {
 let attachmentId: UUID
 let chunkIndex: Int
 }

 // MARK: - Init

 public init(sessionId: String, fileManager: FileManager = .default) {
 self.sessionId = sessionId
 self.root = AppPaths.attachments(forSessionId: sessionId)
 self.schemaURL = AppPaths.attachmentsSchema
 self.fileManager = fileManager
 let encoder = JSONEncoder()
 encoder.dateEncodingStrategy = .iso8601
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 self.encoder = encoder
 let decoder = JSONDecoder()
 decoder.dateDecodingStrategy = .iso8601
 self.decoder = decoder
 }

 // MARK: - Public API

 /// Ingest an `Attachment` value produced by `AttachmentIndexer.ingest`.
 /// Dedup rule: if an attachment with the same `contentHash` is
 /// already in the cache, the incoming value is dropped.
 ///
 /// On success, writes the attachment's JSON to
 /// `<root>/<id>.json`, updates the cache, and invalidates the
 /// inverted index so the next `retrieve(...)` will rebuild it.
 public func ingest(_ attachment: Attachment) async throws {
 try await loadIfNeeded()

 if cache.values.contains(where: { $0.contentHash == attachment.contentHash }) {
 return
 }

 try ensureRootExists()
 let url = fileURL(for: attachment.id)
 let data = try encoder.encode(attachment)
 try data.write(to: url, options: .atomic)

 cache[attachment.id] = attachment
 indexDirty = true
 }

 /// All attachments in this session, sorted by ingestion time
 /// ascending (oldest first). Loads from disk on first call.
 public func all() async -> [Attachment] {
 (try? await loadIfNeeded())

 return cache.values.sorted() { $0.ingestedAt < $1.ingestedAt }
 }

 /// Delete the attachment with `id`. Removes both the on-disk
 /// JSON and the in-memory cache entry. Missing is a no-op.
 public func remove(_ id: UUID) async throws {
 try await loadIfNeeded()
 guard cache[id] != nil else { return }

 let url = fileURL(for: id)
 if fileManager.fileExists(atPath: url.path) {
 try fileManager.removeItem(at: url)
 }
 cache.removeValue(forKey: id)
 indexDirty = true
 }

 /// Rehydrate the cache from disk. Safe to call multiple times —
 /// reuses the `loaded` flag after the first successful pass.
 /// ships a lenient loader: malformed JSON files are
 /// skipped (logged in DEBUG), not fatal.
 public func load() async throws {
 try ensureRootExists()
 cache.removeAll()

 let files: [URL]
 do {
 files = try fileManager.contentsOfDirectory(
 at: root,
 includingPropertiesForKeys: nil
 )
 } catch {
 // Directory doesn't exist or is unreadable — treat as
 // empty store rather than throwing.
 loaded = true
 indexDirty = true
 return
 }

 for file in files where file.pathExtension == "json" {
 guard let data = try? Data(contentsOf: file),
 let attachment = try? decoder.decode(Attachment.self, from: data) else {
 #if DEBUG
 print("[AttachmentStore] skipping malformed file: \(file.lastPathComponent)")
 #endif
 continue
 }
 cache[attachment.id] = attachment
 }

 loaded = true
 indexDirty = true
 }

 // MARK: - Retrieval (internal — used by RetrievalPlanner)

 /// Score chunks against `queryTerms`, return top-K bounded by
 /// `tokenBudget`. Greedy fill by descending score; ties broken
 /// stably on `(attachment.id.uuidString, chunk.position)`.
 internal func retrieve(
 queryTerms: [String],
 topK: Int,
 tokenBudget: Int
 ) async -> [SelectedAttachmentChunk] {
 (try? await loadIfNeeded())

 guard !queryTerms.isEmpty, topK > 0, tokenBudget > 0 else { return [] }

 rebuildIndexIfNeeded()

 // Score each chunk by summing log(1 + TF) over matched terms.
 // For each matched chunk we only need its (attachmentId,
 // chunkIndex) identity to look up the chunk text.
 var chunkScores: [ChunkKey: Double] = [:]
 for term in queryTerms {
 guard let refs = invertedIndex[term] else { continue }
 // Count TF per chunk for this term.
 var tfByKey: [ChunkKey: Int] = [:]
 for ref in refs {
 let key = ChunkKey(attachmentId: ref.attachmentId, chunkIndex: ref.chunkIndex)
 tfByKey[key, default: 0] += 1
 }
 for (key, tf) in tfByKey {
 chunkScores[key, default: 0] += log(1.0 + Double(tf))
 }
 }

 // Collect SelectedChunks with stable tie-break.
 struct Scored {
 let chunkKey: ChunkKey
 let attachmentDisplayName: String
 let chunk: AttachmentChunk
 let score: Double
 }

 var scored: [Scored] = []
 scored.reserveCapacity(chunkScores.count)
 for (key, score) in chunkScores {
 guard let attachment = cache[key.attachmentId],
 key.chunkIndex < attachment.digest.chunks.count else { continue }
 scored.append(Scored(
 chunkKey: key,
 attachmentDisplayName: attachment.displayName,
 chunk: attachment.digest.chunks[key.chunkIndex],
 score: score
 ))
 }

 scored.sort { lhs, rhs in
 if lhs.score != rhs.score { return lhs.score > rhs.score }
 if lhs.chunkKey.attachmentId != rhs.chunkKey.attachmentId {
 return lhs.chunkKey.attachmentId.uuidString < rhs.chunkKey.attachmentId.uuidString
 }
 return lhs.chunkKey.chunkIndex < rhs.chunkKey.chunkIndex
 }

 var out: [SelectedAttachmentChunk] = []
 var tokensUsed = 0
 for s in scored {
 if out.count >= topK { break }
 let cost = s.chunk.tokenEstimate
 if tokensUsed + cost > tokenBudget { continue }
 out.append(SelectedAttachmentChunk(
 attachmentDisplayName: s.attachmentDisplayName,
 chunk: s.chunk,
 score: s.score
 ))
 tokensUsed += cost
 }
 return out
 }

 // MARK: - Index maintenance

 private func rebuildIndexIfNeeded() {
 guard indexDirty else { return }
 invertedIndex.removeAll()
 for (id, attachment) in cache {
 for (i, chunk) in attachment.digest.chunks.enumerated() {
 let terms = AttachmentIndexer.tokenize(chunk.text)
 for term in terms {
 invertedIndex[term, default: []].append(
 ChunkRef(attachmentId: id, chunkIndex: i)
 )
 }
 }
 }
 indexDirty = false
 }

 // MARK: - Helpers

 private func loadIfNeeded() async throws {
 if !loaded {
 try await load()
 }
 }

 private func ensureRootExists() throws {
 let parent = root.deletingLastPathComponent()
 if !fileManager.fileExists(atPath: parent.path) {
 try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
 }
 try StorageContractIO.ensureCompanionHeader(for: contract, at: schemaURL)
 if !fileManager.fileExists(atPath: root.path) {
 try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
 }
 }

 private func fileURL(for id: UUID) -> URL {
 root.appendingPathComponent("\(id.uuidString).json")
 }

 private struct ChunkKey: Hashable, Sendable {
 let attachmentId: UUID
 let chunkIndex: Int
 }
}
