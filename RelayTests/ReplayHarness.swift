import Foundation
@testable import Relay

internal struct ReplayHarness {
 internal struct Execution {
 let runArtifacts: TurnRunArtifacts
 let finalState: AgentSessionState
 let recoveryEvents: [TurnRecoveryEventDiagnostic]

 var currentTurnFocuses: [String] {
 runArtifacts.attempts.compactMap(\.currentTurnFocus)
 }

 var promptSnapshots: [String] {
 runArtifacts.attempts.map(\.systemPrompt)
 }

 var retrievedArtifactCounts: [Int] {
 runArtifacts.attempts.compactMap(\.retrievalDecision?.injectedArtifactCount)
 }
 }

 private enum Step {
 case result(CactusModelHost.CompletionResult)
 case error(Error)
 case empty
 }

 private final class SequenceModelClient: ModelClient, @unchecked Sendable {
 private let steps: [Step]
 private let lock = NSLock
 private var callCount = 0

 init(steps: [Step]) {
 self.steps = steps
 }

 nonisolated func stream(
 messages: [RelayMessage],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions,
 systemPrompt: String?
 ) -> AsyncThrowingStream<CactusModelHost.StreamEvent, Error> {
 lock.lock
 let idx = callCount
 callCount += 1
 lock.unlock

 let step = idx < steps.count ? steps[idx] : .empty
 return AsyncThrowingStream { continuation in
 switch step {
 case .result(let result):
 if !result.text.isEmpty {
 continuation.yield(.token(result.text))
 }
 continuation.yield(.done(result))
 continuation.finish()
 case .error(let error):
 continuation.finish(throwing: error)
 case .empty:
 continuation.finish()
 }
 }
 }
 }

 private final class FixtureFileProvider: FileProviderService, @unchecked Sendable {
 private let root: URL
 private let files: [ReplayWorkspaceFile]

 init(root: URL, files: [ReplayWorkspaceFile]) {
 self.root = root
 self.files = files
 }

 func searchFiles(query: String, inFolder: String?, limit: Int) async throws -> [FileSearchResult] {
 let terms = AttachmentIndexer.tokenize(query)
 guard !terms.isEmpty else { return [] }

 let hits = files.filter { file in
 let haystack = "\(file.relativePath)\n\(file.contents)".lowercased()
 return terms.allSatisfy { haystack.contains($0) }
 }
 return Array(hits.prefix(limit)).map { file in
 FileSearchResult(
 path: root.appendingPathComponent(file.relativePath).path,
 displayName: URL(fileURLWithPath: file.relativePath).lastPathComponent
 )
 }
 }

 func readFile(at path: String) async throws -> Data {
 let url = URL(fileURLWithPath: path)
 guard let match = files.first(where: { root.appendingPathComponent($0.relativePath) == url }) else {
 throw FileProviderError.fileNotFound(path)
 }
 return Data(match.contents.utf8)
 }
 }

 private struct SlowTool: RelayTool {
 var name: String { "slow_echo" }
 var description: String { "slow replay tool" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 try await Task.sleep(nanoseconds: 1_500_000_000)
 return ToolResult(toolUseId: "", output: "slow-ok", isError: false)
 }
 }

 private let fixtureURL: URL

 internal init(fixtureURL: URL) {
 self.fixtureURL = fixtureURL
 }

 internal static func fixtureURL(named name: String) -> URL {
 URL(fileURLWithPath: #filePath)
 .deletingLastPathComponent
 .appendingPathComponent("Fixtures/Replay", isDirectory: true)
 .appendingPathComponent(name)
 }

 internal func loadFixture() throws -> ReplayFixture {
 let data = try Data(contentsOf: fixtureURL)
 let decoder = JSONDecoder()
 decoder.dateDecodingStrategy = .iso8601
 return try decoder.decode(ReplayFixture().self, from: data)
 }

 internal func execute() async throws -> Execution {
 let fixture = try loadFixture
 let tempRoot = FileManager.default.temporaryDirectory
 .appendingPathComponent("replay-harness-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(at: tempRoot) }

 let context = try await makeContextInputs(from: fixture.contextInputs, tempRoot: tempRoot)
 defer {
 if let attachmentStore = context.attachmentStore {
 Task { try? await attachmentStore.removeAllForTesting }
 }
 }

 let builder = ContextBuilder(
 memoryStore: context.memoryStore,
 attachmentStore: context.attachmentStore,
 workspaceURL: context.workspaceURL,
 fileProvider: context.fileProvider
 )
 let onDevice = SequenceModelClient(steps: fixture.onDeviceSteps.map(Self.step))
 let cloud = fixture.cloudSteps.isEmpty ? nil : SequenceModelClient(steps: fixture.cloudSteps.map(Self.step))
 let runner = AgentRunner
 let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream

 let runTask = Task {
 let result = await runner.runWithArtifacts(
 turnID: UUID,
 initialUserMessage: fixture.acceptedUserMessage,
 state: AgentSessionState.hydrated(from: fixture.canonicalHistory),
 contextBuilder: builder,
 onDeviceClient: onDevice,
 cloudClient: cloud,
 dispatcher: ToolDispatcher,
 toolContextFor: Self.toolContextFactory,
 tools: [SlowTool],
 enabledToolNames: ["slow_echo"],
 environment: .current,
 extraSystemContext: context.extraSystemContext,
 options: .init(),
 continuation: continuation
 )
 continuation.finish()
 return result
 }

 var recoveryEvents: [TurnRecoveryEventDiagnostic] = []
 if fixture.expectation.expectInterruptedToolResult {
 for try await event in stream {
 switch event {
 case .toolCallStarted:
 runTask.cancel
 case .recoveryStateChanged(let state):
 recoveryEvents.append(Self.mapRecovery(state))
 case .clearProvisionalOutput:
 recoveryEvents.append(.clearProvisionalOutput)
 default:
 break
 }
 }
 } else {
 for try await event in stream {
 switch event {
 case .recoveryStateChanged(let state):
 recoveryEvents.append(Self.mapRecovery(state))
 case .clearProvisionalOutput:
 recoveryEvents.append(.clearProvisionalOutput)
 default:
 break
 }
 }
 }

 let runResult = await runTask.value
 return Execution(
 runArtifacts: runResult.artifacts,
 finalState: runResult.state,
 recoveryEvents: recoveryEvents
 )
 }

 private static let toolContextFactory: @Sendable ([RelayMessage]) -> ToolCallContext = { messages in
 ToolCallContext(
 messages: messages,
 session: AgentSession(id: "replay", startedAt: Date),
 approvalBroker: DefaultApprovalBroker,
 progress: { _ in },
 services: DefaultServiceLocator
 )
 }

 private struct PreparedContextInputs {
 let memoryStore: MemoryStore?
 let attachmentStore: AttachmentStore?
 let workspaceURL: URL?
 let fileProvider: (any FileProviderService)?
 let extraSystemContext: [String: String]
 }

 private func makeContextInputs(
 from inputs: ReplayContextInputs,
 tempRoot: URL
 ) async throws -> PreparedContextInputs {
 let workspaceURL: URL?
 let fileProvider: (any FileProviderService)?
 if !inputs.workspaceFiles.isEmpty {
 let workspace = tempRoot.appendingPathComponent("workspace", isDirectory: true)
 try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
 for file in inputs.workspaceFiles {
 let url = workspace.appendingPathComponent(file.relativePath)
 try FileManager.default.createDirectory(
 at: url.deletingLastPathComponent,
 withIntermediateDirectories: true
 )
 try file.contents.write(to: url, atomically: true, encoding: .utf8)
 }
 workspaceURL = workspace
 fileProvider = FixtureFileProvider(root: workspace, files: inputs.workspaceFiles)
 } else {
 workspaceURL = inputs.workspacePath.map { URL(fileURLWithPath: $0) }
 fileProvider = nil
 }

 let memoryStore: MemoryStore?
 if !inputs.memoryDocuments.isEmpty {
 let memoryRoot = tempRoot.appendingPathComponent("memory", isDirectory: true)
 let store = MemoryStore(root: memoryRoot)
 for doc in inputs.memoryDocuments {
 try await store.writeFile(doc.fileName, content: doc.contents)
 }
 memoryStore = store
 } else {
 memoryStore = nil
 }

 let attachmentStore: AttachmentStore?
 if !inputs.attachmentDocuments.isEmpty {
 let sessionId = "replay-\(UUID().uuidString)"
 let store = AttachmentStore(sessionId: sessionId)
 for doc in inputs.attachmentDocuments {
 let url = tempRoot.appendingPathComponent(doc.displayName)
 try doc.contents.write(to: url, atomically: true, encoding: .utf8)
 let attachment = try AttachmentIndexer.ingest(
 fileURL: url,
 displayName: doc.displayName
 )
 try await store.ingest(attachment)
 }
 attachmentStore = store
 } else {
 attachmentStore = nil
 }

 var extraSystemContext: [String: String] = [:]
 if let workspaceURL {
 extraSystemContext["Workspace"] = workspaceURL.path
 }

 return PreparedContextInputs(
 memoryStore: memoryStore,
 attachmentStore: attachmentStore,
 workspaceURL: workspaceURL,
 fileProvider: fileProvider,
 extraSystemContext: extraSystemContext
 )
 }

 private static func step(from modelStep: ReplayModelStep) -> Step {
 if let completion = modelStep.completion {
 return .result(completion.asCompletionResult)
 }
 if let error = modelStep.error {
 return .error(Self.error(from: error))
 }
 return .empty
 }

 private static func error(from snapshot: ReplayErrorSnapshot) -> Error {
 switch snapshot.kind {
 case .promptTooLong:
 return CactusModelHost.HostError.inferenceFailed(snapshot.message)
 case .cloudRetryFailed:
 return GeminiClient.GeminiError.networkError(snapshot.message)
 case .interrupted:
 return CancellationError
 case .fatal:
 return CactusModelHost.HostError.inferenceFailed(snapshot.message)
 }
 }

 private static func mapRecovery(_ state: RecoveryDisplayState) -> TurnRecoveryEventDiagnostic {
 switch state {
 case .retryingWithCloud:
 return .retryingWithCloud
 case .compactingContext:
 return .compactingContext
 case .retryingAfterContextReduction:
 return .retryingAfterContextReduction
 case .cleaningUpInterruptedTurn:
 return .cleaningUpInterruptedTurn
 }
 }
}

private extension AttachmentStore {
 func removeAllForTesting() async throws {
 let attachments = await all
 for attachment in attachments {
 try await remove(attachment.id)
 }
 }
}
