import Foundation

public struct MemoryDocument: Sendable, Equatable {
 public let fileName: String
 public let displayName: String
 public let description: String
 public let type: String
 public let body: String

 public init(
 fileName: String,
 displayName: String,
 description: String,
 type: String,
 body: String
 ) {
 self.fileName = fileName
 self.displayName = displayName
 self.description = description
 self.type = type
 self.body = body
 }
}

/// Claude-Code-style memory store: topic-organized markdown files in the
/// iOS app sandbox. No embeddings, no vector search, no hierarchy.
///
/// Layout under `<Application Support>/Relay/memory/`:
/// ```
/// MEMORY.md — always-loaded index, kept under 25 KB
/// user_*.md — user profile/preferences
/// feedback_*.md — behavioral corrections (rule + Why + How)
/// project_*.md — ongoing work context
/// reference_*.md — pointers to external systems
/// ```
///
/// Ports the feature set of `memdir/memdir.ts` + `memdir/paths.ts` from
/// the reference agent, scoped to a single-session iOS agent (no project trees, no
/// background extraction agent, no project docs discovery).
public actor MemoryStore {

 // MARK: - Errors

 public enum MemoryError: Error, Sendable {
 /// Path failed validation (traversal, wrong extension, wrong naming).
 case invalidPath(String)
 /// Content exceeded the per-file size limit.
 case contentTooLarge(bytes: Int, limit: Int)
 /// A `MEMORY.md` rewrite dropped one or more existing bullet lines
 /// (file references). The payload carries the lines the model MUST
 /// include in its retry.
 case indexDroppedEntries([String])
 }

 // MARK: - Limits

 /// Soft cap for a single memory file. the reference agent has no hard cap, but
 /// 50 KB catches accidental tool-result dumping.
 public static let maxFileBytes = 50_000

 /// Bytes of `MEMORY.md` returned by `loadIndex`. Anything beyond is
 /// truncated with a trailing note so the model knows there's more.
 public static let maxIndexBytes = 25_000

 // MARK: - State

 private let root: URL
 private let fileManager: FileManager
 private let contract = StorageRegistry.contract(for: .memoryIndex)

 public init(root: URL = MemoryStore.defaultRoot, fileManager: FileManager = .default) {
 self.root = root
 self.fileManager = fileManager
 }

 /// Canonical on-device location. Created on first use.
 public static var defaultRoot: URL {
 AppPaths.memoryDir
 }

 // MARK: - Public API

 /// Cold-start MEMORY.md stub written when `loadIndex(initializeIfMissing:
 /// true)` is called and the file doesn't exist yet. Single italicized
 /// list item — non-empty so `SystemPrompt.memorySection` falls into the
 /// FULL instruction-block branch (instead of the 30-token minimal stub
 /// branch) on a fresh install. Doesn't match the index-bullet regex
 /// `- [Title](file.md) — hook` used by `indexFileRefs`, so the
 /// no-dropped-entries guard treats it as zero-entry baseline.
 internal static let coldStartIndexStub: String =
 "- _(no facts saved yet — call memory_write when the user shares one)_\n"

 /// Read `MEMORY.md` verbatim. Truncates to `maxIndexBytes` and appends a
 /// tombstone if the file is larger.
 ///
 /// Returns `nil` when the file is missing AND `initializeIfMissing` is
 /// false (default — preserves the legacy contract for Settings UI /
 /// tests that want to detect cold-start state).
 ///
 /// When `initializeIfMissing` is true (Round-6 R6-A.2),
 /// the cold-start stub is atomically written on first read so the
 /// system prompt always renders the full memory section. Idempotent:
 /// existing indexes are never overwritten.
 ///
 /// Never throws — a missing / unreadable index is just a cold start.
 public func loadIndex(
 maxBytes: Int = MemoryStore.maxIndexBytes,
 initializeIfMissing: Bool = false
 ) async -> String? {
 try? ensureDirectory
 let url = root.appendingPathComponent("MEMORY.md")

 // Lazy stub init for cold-start — only runs when caller opts in
 // AND the file is genuinely missing. Existing index untouched.
 if initializeIfMissing,
 !fileManager.fileExists(atPath: url.path),
 let stubData = Self.coldStartIndexStub.data(using: .utf8) {
 try? stubData.write(to: url, options: .atomic)
 }

 guard fileManager.fileExists(atPath: url.path),
 let data = try? Data(contentsOf: url),
 !data.isEmpty
 else { return nil }

 if data.count <= maxBytes {
 return String(data: data, encoding: .utf8)
 }
 let head = data.prefix(maxBytes)
 let text = String(data: head, encoding: .utf8) ?? ""
 return text + "\n\n[…index truncated at \(maxBytes) bytes; see memory/ for full list…]"
 }

 /// List all topic files (not `MEMORY.md`), sorted by name.
 public func listFiles() async throws -> [String] {
 try ensureDirectory
 let items = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
 return items
 .map { $0.lastPathComponent }
 .filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" }
 .sorted()
 }

 /// Read every topic file's body into a `[filename: content]` map, stopping
 /// once the running total exceeds `budgetBytes`. Files larger than the
 /// remaining budget are skipped rather than truncated — truncated YAML
 /// frontmatter would mislead the model. Order is lexicographic (matches
 /// `listFiles`). Never throws: unreadable files are simply skipped.
 ///
 /// Used by `AgentCore` to pack topic bodies into the memory section so
 /// the model can reason over them without a separate `memory_read` tool.
 public func readAllTopics(budgetBytes: Int = 15_000) async -> [String: String] {
 var out: [String: String] = [:]
 guard let names = try? await listFiles else { return out }
 var used = 0
 for name in names {
 guard let body = try? await readFile(name) else { continue }
 let cost = body.utf8.count
 if used + cost > budgetBytes { continue }
 out[name] = body
 used += cost
 }
 return out
 }

 /// Load topic files as retrieval documents rather than inlining every
 /// body into the stable prompt bootstrap. Missing or unreadable files are
 /// skipped. The running total is capped by `budgetBytes`.
 public func loadRetrievalDocuments(budgetBytes: Int = 20_000) async -> [MemoryDocument] {
 var out: [MemoryDocument] = []
 guard let names = try? await listFiles else { return out }

 var used = 0
 for name in names {
 guard let raw = try? await readFile(name) else { continue }
 let cost = raw.lengthOfBytes(using: .utf8)
 if used + cost > budgetBytes { continue }

 let parsed = Self.parseMemoryDocument(fileName: name, raw: raw)
 out.append(parsed)
 used += cost
 }

 return out
 }

 /// Read a single topic file. Throws if the path fails validation or the
 /// file is missing.
 public func readFile(_ relativePath: String) async throws -> String {
 try ensureDirectory
 let url = try validated(relativePath: relativePath)
 return try String(contentsOf: url, encoding: .utf8)
 }

 /// Write or overwrite a topic file. Rejects paths that escape the memory
 /// dir or don't match the topic-file naming convention.
 ///
 /// Special case: writing `MEMORY.md` is validated against the current
 /// on-disk index — every existing `- [name](file.md)` bullet MUST appear
 /// in the new content. This turns "model lazily rewrites index and loses
 /// entries" into a self-correcting error loop instead of silent data
 /// loss. Adding new bullets is always allowed.
 public func writeFile(_ relativePath: String, content: String) async throws {
 try ensureDirectory
 let url = try validated(relativePath: relativePath)

 guard let data = content.data(using: .utf8) else {
 throw MemoryError.invalidPath(relativePath)
 }
 guard data.count <= Self.maxFileBytes else {
 throw MemoryError.contentTooLarge(bytes: data.count, limit: Self.maxFileBytes)
 }

 if relativePath == "MEMORY.md" {
 let previousRefs = Self.indexFileRefs(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
 let incomingRefs = Self.indexFileRefs(in: content)
 let dropped = previousRefs.subtracting(incomingRefs)
 if !dropped.isEmpty {
 throw MemoryError.indexDroppedEntries(dropped.sorted())
 }
 }

 try data.write(to: url, options: .atomic)
 }

 /// Extract the set of `<file>.md` references from `- [label](file.md)`
 /// bullets. Used only to compare "what's in the current index" vs "what
 /// the model wants to write" so we can reject drops.
 private static func indexFileRefs(in body: String) -> Set<String> {
 var refs = Set<String>
 let regex = try? NSRegularExpression(
 pattern: #"\]\(([a-zA-Z0-9_./]+\.md)\)"#
 )
 guard let regex else { return refs }
 let ns = body as NSString
 let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
 for m in matches where m.numberOfRanges > 1 {
 let r = m.range(at: 1)
 if r.location != NSNotFound { refs.insert(ns.substring(with: r)) }
 }
 return refs
 }

 /// Delete a topic file (or `MEMORY.md`). No-op if missing.
 public func deleteFile(_ relativePath: String) async throws {
 try ensureDirectory
 let url = try validated(relativePath: relativePath)
 if fileManager.fileExists(atPath: url.path) {
 try fileManager.removeItem(at: url)
 }
 }

 /// Append a bullet line to `MEMORY.md`. Idempotent on exact duplicates
 /// (the model sometimes updates a file and re-emits the same index
 /// pointer).
 public func appendToIndex(_ line: String) async throws {
 try ensureDirectory
 let url = root.appendingPathComponent("MEMORY.md")
 let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmed.isEmpty else { return }

 let existing: String
 if let data = try? Data(contentsOf: url),
 let s = String(data: data, encoding: .utf8) {
 existing = s
 } else {
 existing = ""
 }

 // Idempotency: don't append a line that already exists verbatim.
 if existing.split(separator: "\n").contains(where: { String($0).trimmingCharacters(in: .whitespaces) == trimmed }) {
 return
 }

 var next = existing
 if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
 next += trimmed + "\n"
 try next.write(to: url, atomically: true, encoding: .utf8)
 }

 /// Remove everything from the memory directory. Used by Settings.
 public func clearAll() async throws {
 guard fileManager.fileExists(atPath: root.path) else { return }
 let items = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
 for url in items {
 try? fileManager.removeItem(at: url)
 }
 }

 /// Filename for the writeback diagnostics log. Hidden (leading `.`) so
 /// it doesn't pollute MemoryFilesView listings, and doesn't match the
 /// topic-file regex so it's never visible as "memory."
 internal static let writebackErrorLogName = ".writeback_errors.log"

 /// Soft cap on lines kept in the writeback error log. When exceeded
 /// we trim to `writebackErrorLogTrimToLines` (drop the oldest, keep
 /// recent failures).
 internal static let writebackErrorLogMaxLines = 100
 internal static let writebackErrorLogTrimToLines = 50

 /// Append one line to the writeback error log (Round-6 R6-A.3,
 /// ). Used by `MemoryWritebackCoordinator.afterTurn` when
 /// a deterministic writeback fails — gives Isaac a durable signal
 /// beyond the Xcode console `print(...)`. Hidden filename bypasses
 /// `validated` (which only accepts topic-file shape).
 ///
 /// Format per line:
 /// `<ISO-8601 timestamp> <fileName> <errorMessage>`
 ///
 /// On overflow (>100 lines), keeps only the most recent 50.
 /// Best-effort: any IO failure is swallowed silently — this is an
 /// observability path, not a correctness path.
 public func appendErrorLog(fileName: String, errorMessage: String) async {
 try? ensureDirectory
 let url = root.appendingPathComponent(Self.writebackErrorLogName)
 let timestamp = ISO8601DateFormatter().string(from: Date)
 let safeMessage = errorMessage.replacingOccurrences(of: "\n", with: " ")
 let safeFile = fileName.replacingOccurrences(of: "\n", with: " ")
 let entry = "\(timestamp) \(safeFile) \(safeMessage)\n"

 let existing: String
 if let data = try? Data(contentsOf: url),
 let s = String(data: data, encoding: .utf8) {
 existing = s
 } else {
 existing = ""
 }
 var combined = existing + entry

 // Rotation: if combined line count exceeds the cap, keep only
 // the most recent N lines (where N = trim target).
 let lines = combined.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
 // `split(omittingEmptySubsequences: false)` produces a trailing
 // empty subsequence after the final newline; that's expected and
 // we discard it when joining below.
 let nonEmptyLines = lines.filter { !$0.isEmpty }
 if nonEmptyLines.count > Self.writebackErrorLogMaxLines {
 let kept = nonEmptyLines.suffix(Self.writebackErrorLogTrimToLines).map(String.init())
 combined = kept.joined(separator: "\n") + "\n"
 }

 if let outData = combined.data(using: .utf8) {
 try? outData.write(to: url, options: .atomic)
 }
 }

 // MARK: - Path validation

 /// Accepted shapes:
 /// `MEMORY.md` (the index)
 /// `<type>_<topic>.md`, type ∈ {user, feedback, project, reference},
 /// topic is lowercase alnum + underscore
 ///
 /// Rejects traversal, subdirectories, and any non-.md extension.
 private func validated(relativePath: String) throws -> URL {
 let name = relativePath
 guard !name.isEmpty,
 !name.contains("/"),
 !name.contains(".."),
 name.hasSuffix(".md")
 else {
 throw MemoryError.invalidPath(relativePath)
 }
 if name == "MEMORY.md" {
 return root.appendingPathComponent(name)
 }
 // Topic file regex. Kept inline instead of a stored NSRegularExpression
 // because validation is cold-path.
 let pattern = "^(user|feedback|project|reference)_[a-z0-9_]+\\.md$"
 if name.range(of: pattern, options: .regularExpression) == nil {
 throw MemoryError.invalidPath(relativePath)
 }
 return root.appendingPathComponent(name)
 }

 private func ensureDirectory() throws {
 if !fileManager.fileExists(atPath: root.path) {
 try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
 }
 let schemaURL = root.appendingPathComponent("schema.json")
 try StorageContractIO.ensureCompanionHeader(for: contract, at: schemaURL)
 }

 private static func parseMemoryDocument(fileName: String, raw: String) -> MemoryDocument {
 let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
 let fallbackDisplayName = fileName
 .replacingOccurrences(of: ".md", with: "")
 .replacingOccurrences(of: "_", with: " ")

 guard trimmed.hasPrefix("---\n") || trimmed == "---" || trimmed.hasPrefix("---\r\n") else {
 return MemoryDocument(
 fileName: fileName,
 displayName: fallbackDisplayName,
 description: "",
 type: "",
 body: trimmed
 )
 }

 let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
 guard normalized.hasPrefix("---\n") else {
 return MemoryDocument(
 fileName: fileName,
 displayName: fallbackDisplayName,
 description: "",
 type: "",
 body: trimmed
 )
 }

 let content = String(normalized.dropFirst(4))
 guard let closeRange = content.range(of: "\n---\n") else {
 return MemoryDocument(
 fileName: fileName,
 displayName: fallbackDisplayName,
 description: "",
 type: "",
 body: trimmed
 )
 }

 let frontmatter = String(content[..<closeRange.lowerBound])
 let body = String(content[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

 var fields: [String: String] = [:]
 for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: true) {
 guard let colon = line.firstIndex(of: ":") else { continue }
 let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
 let value = line[line.index(after: colon)...]
 .trimmingCharacters(in: .whitespacesAndNewlines)
 fields[key] = value
 }

 return MemoryDocument(
 fileName: fileName,
 displayName: fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackDisplayName,
 description: fields["description"] ?? "",
 type: fields["type"] ?? "",
 body: body
 )
 }
}
