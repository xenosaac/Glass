import Foundation

/// Canonical file paths for all Relay app data.
///
/// Everything lives under `Application Support/Relay/`.
/// On app delete, this directory is wiped — matching the "local-only, delete = clean" design.
public enum AppPaths {

 /// Root: `~/Library/Application Support/Relay/`
 public static var base: URL {
 FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
 .appendingPathComponent("Relay", isDirectory: true)
 }

 /// JSONL session transcripts directory.
 public static var sessions: URL {
 base.appendingPathComponent("sessions", isDirectory: true)
 }

 /// Session transcript schema companion.
 public static var sessionSchema: URL {
 sessions.appendingPathComponent("schema.json")
 }

 /// Session index metadata envelope.
 public static var sessionIndex: URL {
 sessions.appendingPathComponent("index.json")
 }

 /// Path for a specific session's JSONL file.
 public static func sessionFile(id: String) -> URL {
 sessions.appendingPathComponent("\(id).jsonl")
 }

 /// Claude-Code-style memory directory (`MEMORY.md` + topic files).
 /// Populated by Work Stream C's MemoryStore.
 public static var memoryDir: URL {
 base.appendingPathComponent("memory", isDirectory: true)
 }

 /// Memory schema companion.
 public static var memorySchema: URL {
 memoryDir.appendingPathComponent("schema.json")
 }

 /// Security-scoped bookmarks for authorized folders.
 public static var bookmarks: URL {
 base.appendingPathComponent("bookmarks.json")
 }

 /// Folder indexing registry.
 public static var folderIndex: URL {
 base.appendingPathComponent("folderIndex.json")
 }

 /// Voice recordings directory (durable across sessions, not tmp/).
 public static var voiceRecordings: URL {
 base.appendingPathComponent("voice", isDirectory: true)
 }

 /// attachments root: `Application Support/Relay/attachments/`.
 /// Parent of every session-scoped subdirectory created by
 /// `AttachmentStore(sessionId:)`.
 public static var attachments: URL {
 base.appendingPathComponent("attachments", isDirectory: true)
 }

 /// Attachment schema companion.
 public static var attachmentsSchema: URL {
 attachments.appendingPathComponent("schema.json")
 }

 /// session-scoped attachments directory:
 /// `Application Support/Relay/attachments/<sessionId>/`. Each
 /// attachment is persisted here as a single `<attachmentId>.json`
 /// file. `AttachmentStore.load` rehydrates from this path.
 public static func attachments(forSessionId sessionId: String) -> URL {
 attachments.appendingPathComponent(sessionId, isDirectory: true)
 }

 /// Session-scoped imported media root used by ingress normalization.
 /// User-selected images are copied here before they are persisted into
 /// transcript history so replay never depends on temporary picker URLs.
 public static var sessionMediaRoot: URL {
 base.appendingPathComponent("session-media", isDirectory: true)
 }

 /// Canonical per-session media directory.
 public static func sessionMedia(forSessionId sessionId: String) -> URL {
 sessionMediaRoot.appendingPathComponent(sessionId, isDirectory: true)
 }

 /// Failure-turn runtime sidecar root.
 public static var runtimeSidecars: URL {
 base.appendingPathComponent("runtime-sidecars", isDirectory: true)
 }

 /// Derived replay-fixture export root.
 public static var replayFixtures: URL {
 base.appendingPathComponent("replay-fixtures", isDirectory: true)
 }

 /// MCP config directory.
 public static var mcp: URL {
 base.appendingPathComponent("mcp", isDirectory: true)
 }

 /// File-backed MCP server configuration store.
 public static var mcpServers: URL {
 mcp.appendingPathComponent("servers.json")
 }

 /// Canonical per-session runtime sidecar directory.
 public static func runtimeSidecars(forSessionId sessionId: String) -> URL {
 runtimeSidecars.appendingPathComponent(sessionId, isDirectory: true)
 }

 /// Writable cache for models copied out of the read-only app bundle.
 /// Cactus cannot reliably initialize from the bundle path on device, so
 /// bundled models are hydrated here on first use and loaded from this
 /// directory afterward.
 public static var hydratedModels: URL {
 base.appendingPathComponent("hydrated-models", isDirectory: true)
 }

 /// Writable Gemma path after first-launch hydration from the bundle.
 public static var hydratedGemmaE2BModel: URL {
 hydratedModels.appendingPathComponent("gemma-4-e2b-it", isDirectory: true)
 }

 /// Writable Whisper path after first-launch hydration from the bundle.
 public static var hydratedWhisperModel: URL {
 hydratedModels.appendingPathComponent("whisper-small", isDirectory: true)
 }

 /// Writable FunctionGemma path after first-launch hydration from the bundle.
 public static var hydratedFunctionGemmaModel: URL {
 hydratedModels.appendingPathComponent("functiongemma-270m-it", isDirectory: true)
 }

 // MARK: - Model Paths (Documents folder for sideloading)

 /// Documents directory — visible in Files app, used for model sideloading.
 public static var documents: URL {
 FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
 }

 /// Models directory: `Documents/models/`
 public static var models: URL {
 documents.appendingPathComponent("models", isDirectory: true)
 }

 /// Gemma-4-E2B model weights: `Documents/models/gemma-4-e2b-it/`
 public static var gemmaE2BModel: URL {
 models.appendingPathComponent("gemma-4-e2b-it", isDirectory: true)
 }

 /// Whisper-small model for transcription: `Documents/models/whisper-small/`
 public static var whisperModel: URL {
 models.appendingPathComponent("whisper-small", isDirectory: true)
 }

 /// FunctionGemma-270M specialist model: `Documents/models/functiongemma-270m-it/`
 public static var functionGemmaModel: URL {
 models.appendingPathComponent("functiongemma-270m-it", isDirectory: true)
 }

 /// Check if a model exists at the given path.
 public static func modelExists(at url: URL) -> Bool {
 FileManager.default.fileExists(atPath: url.path)
 }

 /// Creates all required directories. Safe to call at every launch.
 public static func createIfNeeded() throws {
 let fm = FileManager.default
 for dir in [base, memoryDir, sessions, models, voiceRecordings, hydratedModels, attachments, sessionMediaRoot, runtimeSidecars, replayFixtures, mcp] {
 if !fm.fileExists(atPath: dir.path) {
 try fm.createDirectory(at: dir, withIntermediateDirectories: true)
 }
 }
 }

 // MARK: - Bundle-aware model resolution
 //
 // Release builds ship Gemma-4-E2B and whisper-small inside the app
 // bundle, so a fresh install works without sideloading. The resolver
 // probes the bundle first (two candidate layouts so the code survives
 // either direct external folder references OR a fallback Relay/Models
 // copy without Swift edits) and only falls back to Documents/models for
 // developer hot-swap.

 public enum ModelSource: String, Sendable, Equatable {
 case hydratedBundle
 case bundle
 case documents
 }

 public struct ResolvedModel: Sendable, Equatable {
 public let url: URL
 public let source: ModelSource
 }

 private static let gemmaBundleCandidates = [
 "gemma-4-e2b-it",
 "Models/gemma-4-e2b-it",
 ]
 private static let whisperBundleCandidates = [
 "whisper-small",
 "Models/whisper-small",
 ]
 private static let functionGemmaBundleCandidates = [
 "functiongemma-270m-it",
 "Models/functiongemma-270m-it",
 ]

 public static func resolveGemmaE2B() -> ResolvedModel? {
 resolve(
 bundleCandidates: gemmaBundleCandidates,
 hydratedDestination: hydratedGemmaE2BModel,
 documentsFallback: gemmaE2BModel
 )
 }

 public static func resolveWhisperSmall() -> ResolvedModel? {
 resolve(
 bundleCandidates: whisperBundleCandidates,
 hydratedDestination: hydratedWhisperModel,
 documentsFallback: whisperModel
 )
 }

 public static func resolveFunctionGemma() -> ResolvedModel? {
 resolve(
 bundleCandidates: functionGemmaBundleCandidates,
 hydratedDestination: hydratedFunctionGemmaModel,
 documentsFallback: functionGemmaModel
 )
 }

 private static func resolve(
 bundleCandidates: [String],
 hydratedDestination: URL,
 documentsFallback: URL
 ) -> ResolvedModel? {
 if modelDirectoryLooksValid(hydratedDestination) {
 return ResolvedModel(url: hydratedDestination, source: .hydratedBundle)
 }
 if let root = Bundle.main.resourceURL {
 for sub in bundleCandidates {
 let url = root.appendingPathComponent(sub, isDirectory: true)
 if modelDirectoryLooksValid(url) {
 return ResolvedModel(url: url, source: .bundle)
 }
 }
 }
 if modelDirectoryLooksValid(documentsFallback) {
 return ResolvedModel(url: documentsFallback, source: .documents)
 }
 return nil
 }

 public static func prepareGemmaE2BForLoad() async throws -> ResolvedModel? {
 try await prepareForLoad(
 bundleCandidates: gemmaBundleCandidates,
 hydratedDestination: hydratedGemmaE2BModel,
 documentsFallback: gemmaE2BModel
 )
 }

 public static func prepareWhisperSmallForLoad() async throws -> ResolvedModel? {
 try await prepareForLoad(
 bundleCandidates: whisperBundleCandidates,
 hydratedDestination: hydratedWhisperModel,
 documentsFallback: whisperModel
 )
 }

 public static func prepareFunctionGemmaForLoad() async throws -> ResolvedModel? {
 try await prepareForLoad(
 bundleCandidates: functionGemmaBundleCandidates,
 hydratedDestination: hydratedFunctionGemmaModel,
 documentsFallback: functionGemmaModel
 )
 }

 private static func prepareForLoad(
 bundleCandidates: [String],
 hydratedDestination: URL,
 documentsFallback: URL
 ) async throws -> ResolvedModel? {
 try createIfNeeded

 if modelDirectoryLooksValid(hydratedDestination) {
 return ResolvedModel(url: hydratedDestination, source: .hydratedBundle)
 }

 if let root = Bundle.main.resourceURL {
 for sub in bundleCandidates {
 let url = root.appendingPathComponent(sub, isDirectory: true)
 if modelDirectoryLooksValid(url) {
 try await hydrateBundledModelIfNeeded(from: url, to: hydratedDestination)
 return ResolvedModel(url: hydratedDestination, source: .hydratedBundle)
 }
 }
 }

 if modelDirectoryLooksValid(documentsFallback) {
 return ResolvedModel(url: documentsFallback, source: .documents)
 }

 return nil
 }

 private static func hydrateBundledModelIfNeeded(from source: URL, to destination: URL) async throws {
 if modelDirectoryLooksValid(destination) {
 return
 }

 try await Task.detached(priority: .userInitiated) {
 let fm = FileManager.default
 let parent = destination.deletingLastPathComponent
 let staging = parent.appendingPathComponent("\(destination.lastPathComponent).staging", isDirectory: true)

 if !fm.fileExists(atPath: parent.path) {
 try fm.createDirectory(at: parent, withIntermediateDirectories: true)
 }

 if fm.fileExists(atPath: staging.path) {
 try fm.removeItem(at: staging)
 }

 if fm.fileExists(atPath: destination.path) {
 try fm.removeItem(at: destination)
 }

 try fm.copyItem(at: source, to: staging)
 try fm.moveItem(at: staging, to: destination)
 }.value
 }

 private static func modelDirectoryLooksValid(_ url: URL) -> Bool {
 let fm = FileManager.default
 guard fm.fileExists(atPath: url.path, isDirectory: nil) else { return false }
 return fm.fileExists(atPath: url.appendingPathComponent("config.txt").path)
 }
}
