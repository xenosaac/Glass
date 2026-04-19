import Foundation

internal struct TurnRuntimeSidecar: Sendable, Codable {
 internal let sessionId: String
 internal let turnID: UUID
 internal let capturedAt: Date
 internal let failureKind: TurnFailureKind
 internal let canonicalTranscriptSnapshot: [RelayMessage]
 internal let acceptedUserMessage: RelayMessage
 internal let attempts: [TurnAttemptDiagnostics]
 internal let commitTrace: TurnCommitTrace
 internal let recoveryState: RecoveryState
 internal let terminalErrorMessage: String?

 internal init(
 sessionId: String,
 turnID: UUID,
 capturedAt: Date = Date(),
 failureKind: TurnFailureKind,
 canonicalTranscriptSnapshot: [RelayMessage],
 acceptedUserMessage: RelayMessage,
 attempts: [TurnAttemptDiagnostics],
 commitTrace: TurnCommitTrace,
 recoveryState: RecoveryState,
 terminalErrorMessage: String?
 ) {
 self.sessionId = sessionId
 self.turnID = turnID
 self.capturedAt = capturedAt
 self.failureKind = failureKind
 self.canonicalTranscriptSnapshot = canonicalTranscriptSnapshot
 self.acceptedUserMessage = acceptedUserMessage
 self.attempts = attempts
 self.commitTrace = commitTrace
 self.recoveryState = recoveryState
 self.terminalErrorMessage = terminalErrorMessage
 }
}

internal actor RuntimeSidecarStore {
 internal let sessionId: String
 private let baseDir: URL
 private let encoder: JSONEncoder
 private let decoder: JSONDecoder
 private let contract = StorageRegistry.contract(for: .runtimeSidecar)

 internal init(sessionId: String, baseDir: URL? = nil) {
 self.sessionId = sessionId
 self.baseDir = baseDir ?? AppPaths.runtimeSidecars(forSessionId: sessionId)
 self.encoder = JSONEncoder()
 self.encoder.dateEncodingStrategy = .iso8601
 self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 self.decoder = JSONDecoder()
 self.decoder.dateDecodingStrategy = .iso8601
 }

 internal func save(_ sidecar: TurnRuntimeSidecar) throws -> URL {
 try AppPaths.createIfNeeded()
 try ensureDirectoryExists()
 let url = fileURL(for: sidecar.turnID)
 let envelope = VersionedStoreEnvelope(header: contract.schemaHeader, payload: sidecar)
 let data = try encoder.encode(envelope)
 try data.write(to: url, options: .atomic)
 return url
 }

 internal func load(turnID: UUID) throws -> TurnRuntimeSidecar? {
 let url = fileURL(for: turnID)
 guard FileManager.default.fileExists(atPath: url.path) else { return nil }
 let data = try Data(contentsOf: url)
 return try decodeSidecar(data, at: url)
 }

 internal func loadAll() throws -> [TurnRuntimeSidecar] {
 guard FileManager.default.fileExists(atPath: baseDir.path) else { return [] }
 let urls = try FileManager.default.contentsOfDirectory(
 at: baseDir,
 includingPropertiesForKeys: nil
 )
 return try urls
 .filter { $0.pathExtension == "json" }
 .sorted() { $0.lastPathComponent < $1.lastPathComponent }
 .compactMap {
 let data = try Data(contentsOf: $0)
 return try decodeSidecar(data, at: $0)
 }
 }

 private func fileURL(for turnID: UUID) -> URL {
 baseDir.appendingPathComponent("\(turnID.uuidString).json")
 }

 private func ensureDirectoryExists() throws {
 if !FileManager.default.fileExists(atPath: baseDir.path) {
 try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
 }
 }

 private func decodeSidecar(_ data: Data, at url: URL) throws -> TurnRuntimeSidecar? {
 if let envelope = try? decoder.decode(VersionedStoreEnvelope<TurnRuntimeSidecar>.self, from: data) {
 guard envelope.header.isCompatible(with: contract) else {
 _ = try? StorageContractIO.archiveItemIfExists(at: url, storeID: contract.id)
 return nil
 }
 return envelope.payload
 }

 if let legacy = try? decoder.decode(TurnRuntimeSidecar.self, from: data) {
 let migrated = VersionedStoreEnvelope(header: contract.schemaHeader, payload: legacy)
 let migratedData = try encoder.encode(migrated)
 try migratedData.write(to: url, options: .atomic)
 return legacy
 }

 _ = try? StorageContractIO.archiveItemIfExists(at: url, storeID: contract.id)
 return nil
 }
}

internal struct ReplayContextInputs: Sendable, Codable, Equatable {
 internal let workspacePath: String?
 internal let workspaceFiles: [ReplayWorkspaceFile]
 internal let attachmentDocuments: [ReplayAttachmentDocument]
 internal let memoryDocuments: [ReplayMemoryDocument]

 internal init(
 workspacePath: String? = nil,
 workspaceFiles: [ReplayWorkspaceFile] = [],
 attachmentDocuments: [ReplayAttachmentDocument] = [],
 memoryDocuments: [ReplayMemoryDocument] = []
 ) {
 self.workspacePath = workspacePath
 self.workspaceFiles = workspaceFiles
 self.attachmentDocuments = attachmentDocuments
 self.memoryDocuments = memoryDocuments
 }
}

internal struct ReplayWorkspaceFile: Sendable, Codable, Equatable {
 internal let relativePath: String
 internal let contents: String

 internal init(relativePath: String, contents: String) {
 self.relativePath = relativePath
 self.contents = contents
 }
}

internal struct ReplayAttachmentDocument: Sendable, Codable, Equatable {
 internal let displayName: String
 internal let contents: String

 internal init(displayName: String, contents: String) {
 self.displayName = displayName
 self.contents = contents
 }
}

internal struct ReplayMemoryDocument: Sendable, Codable, Equatable {
 internal let fileName: String
 internal let contents: String

 internal init(fileName: String, contents: String) {
 self.fileName = fileName
 self.contents = contents
 }
}

internal struct ReplayErrorSnapshot: Sendable, Codable, Equatable {
 internal enum Kind: String, Sendable, Codable, Equatable {
 case promptTooLong
 case cloudRetryFailed
 case interrupted
 case fatal
 }

 internal let kind: Kind
 internal let message: String

 internal init(kind: Kind, message: String) {
 self.kind = kind
 self.message = message
 }
}

internal struct ReplayModelStep: Sendable, Codable {
 internal let completion: AttemptCompletionSnapshot?
 internal let error: ReplayErrorSnapshot?
 internal let isEmpty: Bool

 internal init(
 completion: AttemptCompletionSnapshot? = nil,
 error: ReplayErrorSnapshot? = nil,
 isEmpty: Bool = false
 ) {
 self.completion = completion
 self.error = error
 self.isEmpty = isEmpty
 }
}

internal struct ReplayExpectation: Sendable, Codable, Equatable {
 internal let exit: TurnExitSummary
 internal let recoveryEvents: [TurnRecoveryEventDiagnostic]
 internal let commitStages: [TurnCommitStage]
 internal let focusMustContain: [String]
 internal let promptMustContain: [String]
 internal let expectedRetrievedArtifactCount: Int?
 internal let expectInterruptedToolResult: Bool

 internal init(
 exit: TurnExitSummary,
 recoveryEvents: [TurnRecoveryEventDiagnostic] = [],
 commitStages: [TurnCommitStage] = [],
 focusMustContain: [String] = [],
 promptMustContain: [String] = [],
 expectedRetrievedArtifactCount: Int? = nil,
 expectInterruptedToolResult: Bool = false
 ) {
 self.exit = exit
 self.recoveryEvents = recoveryEvents
 self.commitStages = commitStages
 self.focusMustContain = focusMustContain
 self.promptMustContain = promptMustContain
 self.expectedRetrievedArtifactCount = expectedRetrievedArtifactCount
 self.expectInterruptedToolResult = expectInterruptedToolResult
 }
}

internal struct ReplayFixture: Sendable, Codable {
 internal let name: String
 internal let canonicalHistory: [RelayMessage]
 internal let acceptedUserMessage: RelayMessage
 internal let contextInputs: ReplayContextInputs
 internal let onDeviceSteps: [ReplayModelStep]
 internal let cloudSteps: [ReplayModelStep]
 internal let expectation: ReplayExpectation

 internal init(
 name: String,
 canonicalHistory: [RelayMessage],
 acceptedUserMessage: RelayMessage,
 contextInputs: ReplayContextInputs = .init(),
 onDeviceSteps: [ReplayModelStep],
 cloudSteps: [ReplayModelStep] = [],
 expectation: ReplayExpectation
 ) {
 self.name = name
 self.canonicalHistory = canonicalHistory
 self.acceptedUserMessage = acceptedUserMessage
 self.contextInputs = contextInputs
 self.onDeviceSteps = onDeviceSteps
 self.cloudSteps = cloudSteps
 self.expectation = expectation
 }
}

internal actor ReplayFixtureStore {
 private let baseDir: URL
 private let encoder: JSONEncoder
 private let decoder: JSONDecoder
 private let contract = StorageRegistry.contract(for: .replayFixtureExport)

 internal init(baseDir: URL = AppPaths.replayFixtures) {
 self.baseDir = baseDir
 self.encoder = JSONEncoder()
 self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 self.decoder = JSONDecoder()
 }

 @discardableResult
 internal func save(_ fixture: ReplayFixture, name: String) throws -> URL {
 try ensureDirectoryExists()
 let url = fileURL(for: name)
 let envelope = VersionedStoreEnvelope(header: contract.schemaHeader, payload: fixture)
 let data = try encoder.encode(envelope)
 try data.write(to: url, options: .atomic)
 return url
 }

 internal func load(name: String) throws -> ReplayFixture? {
 let url = fileURL(for: name)
 guard FileManager.default.fileExists(atPath: url.path) else { return nil }
 let data = try Data(contentsOf: url)

 if let envelope = try? decoder.decode(VersionedStoreEnvelope<ReplayFixture>.self, from: data) {
 guard envelope.header.isCompatible(with: contract) else {
 try? FileManager.default.removeItem(at: url)
 return nil
 }
 return envelope.payload
 }

 if let legacy = try? decoder.decode(ReplayFixture.self, from: data) {
 _ = try save(legacy, name: name)
 return legacy
 }

 try? FileManager.default.removeItem(at: url)
 return nil
 }

 private func ensureDirectoryExists() throws {
 if !FileManager.default.fileExists(atPath: baseDir.path) {
 try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
 }
 }

 private func fileURL(for name: String) -> URL {
 let safe = name
 .lowercased()
 .replacingOccurrences(of: " ", with: "-")
 .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
 let fallback = safe.isEmpty ? UUID().uuidString.lowercased() : safe
 return baseDir.appendingPathComponent("\(fallback).json")
 }
}

internal struct ReplayFixtureExporter: Sendable {
 internal init() {}

 internal func export(_ sidecar: TurnRuntimeSidecar) -> ReplayFixture {
 let sanitizer = ReplaySanitizer(sessionId: sidecar.sessionId)
 let recoveryEvents = sidecar.attempts.flatMap(\.emittedRecoveryEvents)
 let onDeviceSteps = sidecar.attempts
 .filter { $0.modelTier != .cloud }
 .map(step(from:))
 let cloudSteps = sidecar.attempts
 .filter { $0.modelTier == .cloud }
 .map(step(from:))

 let focusSnippets = sidecar.attempts
 .compactMap(\.currentTurnFocus)
 .flatMap { focus in
 focus
 .components(separatedBy: "\n")
 .filter {
 $0.hasPrefix("- Turn classification:")
 || $0 == "Latest user message:"
 }
 }
 let promptSnippets = sidecar.attempts
 .map(\.systemPrompt)
 .flatMap { prompt in
 prompt
 .components(separatedBy: "\n")
 .filter { $0.contains("Current turn focus") || $0.contains("Recovery") }
 }

 return ReplayFixture(
 name: "replay-\(sidecar.failureKind.rawValue)",
 canonicalHistory: sanitizer.sanitize(sidecar.canonicalTranscriptSnapshot),
 acceptedUserMessage: sanitizer.sanitize(sidecar.acceptedUserMessage),
 onDeviceSteps: onDeviceSteps,
 cloudSteps: cloudSteps,
 expectation: ReplayExpectation(
 exit: sidecar.failureKind.asExitSummary,
 recoveryEvents: recoveryEvents,
 commitStages: sidecar.commitTrace.entries.map(\.stage),
 focusMustContain: Array(Set(focusSnippets)).sorted(),
 promptMustContain: Array(Set(promptSnippets)).sorted()
 )
 )
 }

 private func step(from attempt: TurnAttemptDiagnostics) -> ReplayModelStep {
 if let completion = attempt.completionSnapshot {
 return ReplayModelStep(completion: completion)
 }
 if let errorSummary = attempt.errorSummary {
 return ReplayModelStep(error: ReplayErrorSnapshot(
 kind: classifyErrorKind(for: attempt, message: errorSummary),
 message: errorSummary
 ))
 }
 return ReplayModelStep(isEmpty: true)
 }

 private func classifyErrorKind(
 for attempt: TurnAttemptDiagnostics,
 message: String
 ) -> ReplayErrorSnapshot.Kind {
 let normalized = message.lowercased()
 if normalized.contains("prompt too long")
 || normalized.contains("context window")
 || normalized.contains("too many tokens")
 || normalized.contains("request too large") {
 return .promptTooLong
 }
 if attempt.modelTier == .cloud {
 return .cloudRetryFailed
 }
 return .fatal
 }
}

private struct ReplaySanitizer {
 let sessionId: String
 private let sanitizedFileURL = URL(string: "file:///SANITIZED_PATH")!

 func sanitize(_ messages: [RelayMessage]) -> [RelayMessage] {
 messages.map(sanitize)
 }

 func sanitize(_ message: RelayMessage) -> RelayMessage {
 switch message {
 case .user(let content):
 return .user(UserContent(
 blocks: content.blocks.map(sanitize),
 isMeta: content.isMeta
 ))
 case .assistant(let content):
 return .assistant(AssistantContent(
 blocks: content.blocks.map(sanitize)
 ))
 case .toolResult(let blocks):
 return .toolResult(blocks.map { block in
 ToolResultBlock(
 toolUseId: sanitizeText(block.toolUseId),
 output: sanitizeText(block.output),
 isError: block.isError,
 metadata: block.metadata?.mapValues(sanitizeText)
 )
 })
 }
 }

 private func sanitize(_ block: UserBlock) -> UserBlock {
 switch block {
 case .text(let text):
 return .text(sanitizeText(text))
 case .audioRef:
 return .audioRef(sanitizedFileURL)
 case .image:
 return .image(sanitizedFileURL)
 case .fileRef(let ref):
 return .fileRef(ImportedFileRef(
 attachmentID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
 displayName: sanitizeText(ref.displayName),
 contentTypeIdentifier: ref.contentTypeIdentifier
 ))
 }
 }

 private func sanitize(_ block: AssistantBlock) -> AssistantBlock {
 switch block {
 case .text(let text):
 return .text(sanitizeText(text))
 case .toolUse(let block):
 return .toolUse(ToolUseBlock(
 id: sanitizeText(block.id),
 name: sanitizeText(block.name),
 inputJson: sanitizeText(block.inputJson)
 ))
 }
 }

 private func sanitizeText(_ text: String) -> String {
 text
 .replacingOccurrences(of: sessionId, with: "<session-id>")
 .replacingOccurrences(
 of: #"file:///[^"\s<>\)]+"#,
 with: "file:///SANITIZED_PATH",
 options: .regularExpression
 )
 .replacingOccurrences(
 of: #"/(?:Users|private|var|tmp|Applications|System)[^"\s<>\)]+"#,
 with: "<path>",
 options: .regularExpression
 )
 .replacingOccurrences(
 of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
 with: "<uuid>",
 options: .regularExpression
 )
 }
}

private extension TurnFailureKind {
 var asExitSummary: TurnExitSummary {
 switch self {
 case .modelError:
 return .modelError
 case .noCompletion:
 return .noCompletion
 case .maxTurns:
 return .maxTurns
 case .interrupted:
 return .interrupted
 }
 }
}
