import XCTest
@testable import Relay

final class RetrievalPlannerTests: XCTestCase {

 private final class StubFileProvider: FileProviderService, @unchecked Sendable {
 let results: [FileSearchResult]
 let fileData: [String: Data]

 init(results: [FileSearchResult] = [], fileData: [String: Data] = [:]) {
 self.results = results
 self.fileData = fileData
 }

 func searchFiles(query: String, inFolder: String?, limit: Int) async throws -> [FileSearchResult] {
 Array(results.prefix(limit))
 }

 func readFile(at path: String) async throws -> Data {
 guard let data = fileData[path] else {
 throw FileProviderError.fileNotFound(path)
 }
 return data
 }
 }

 private func makeAttachment(
 content: String,
 displayName: String = "fixture.txt",
 chunkByteTarget: Int = 64
 ) throws -> Attachment {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayRetrievalPlannerTests-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 let url = dir.appendingPathComponent(displayName)
 try content.data(using: .utf8)!.write(to: url)
 return try AttachmentIndexer(
 chunkByteTarget: chunkByteTarget,
 chunkOverlapBytes: 0,
 maxChunks: 1_000
 ).ingest(fileURL: url, displayName: displayName)
 }

 private func makeAnalysis(
 text: String,
 classification: TurnClassification = .question
 ) -> TurnAnalysis {
 TurnAnalysis(
 latestUserText: text,
 normalizedLatestText: text.lowercased(),
 classification: classification,
 salientTerms: Set(AttachmentIndexer.tokenize(text)),
 recentTailStrategy: .none,
 visibleFactTexts: [],
 responseDirective: "test"
 )
 }

 private func makeMemoryStore() throws -> (store: MemoryStore, root: URL) {
 let root = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayMemoryRetrieval-\(UUID().uuidString)", isDirectory: true)
 return (MemoryStore(root: root), root)
 }

 private func cleanSessionDir(_ sessionId: String) {
 try? FileManager.default.removeItem(at: AppPaths.attachments(forSessionId: sessionId))
 }

 func test_plan_questionWithAttachmentHit_returnsAttachmentArtifact() async throws {
 let sid = "planner-attachment-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(makeAttachment(content: "reset the device via the power button"))

 let planner = RetrievalPlanner
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "how do I reset the device?"),
 memoryStore: nil,
 attachmentStore: store,
 workspaceURL: nil,
 fileProvider: nil
 )

 XCTAssertEqual(decision.query, "how do I reset the device?")
 XCTAssertEqual(decision.artifacts.first?.artifact.kind, .attachment)
 XCTAssertEqual(decision.artifacts.first?.artifact.sourceDisplayName, "fixture.txt")
 }

 func test_plan_questionWithMemoryHit_returnsMemoryArtifact() async throws {
 let (store, root) = try makeMemoryStore
 defer { try? FileManager.default.removeItem(at: root) }

 try await store.writeFile(
 "user_profile.md",
 content: """
 ---
 name: User Profile
 description: user identity details
 type: user
 ---

 My name is Isaac and I run the relay project.
 """
 )

 let planner = RetrievalPlanner
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "what is my name?"),
 memoryStore: store,
 attachmentStore: nil,
 workspaceURL: nil,
 fileProvider: nil
 )

 XCTAssertEqual(decision.artifacts.first?.artifact.kind, .memory)
 XCTAssertEqual(decision.artifacts.first?.artifact.id, "user_profile.md")
 XCTAssertEqual(decision.artifacts.first?.artifact.sourceDisplayName, "User Profile")
 }

 func test_plan_questionWithWorkspaceHit_returnsWorkspaceArtifact() async throws {
 let workspace = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayWorkspace-\(UUID().uuidString)", isDirectory: true)
 let readme = workspace.appendingPathComponent("Guide.txt")
 let provider = StubFileProvider(
 results: [FileSearchResult(path: readme.path, displayName: "Guide.txt")],
 fileData: [readme.path: Data("Reset the device by holding the power button.".utf8)]
 )

 let planner = RetrievalPlanner
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "how do I reset the device?"),
 memoryStore: nil,
 attachmentStore: nil,
 workspaceURL: workspace,
 fileProvider: provider
 )

 XCTAssertEqual(decision.artifacts.first?.artifact.kind, .workspace)
 XCTAssertEqual(decision.artifacts.first?.artifact.id, "Guide.txt")
 XCTAssertEqual(decision.artifacts.first?.artifact.sourceDisplayName, "Guide.txt")
 }

 func test_plan_noQueryTerms_returnsEmptyDecision() async {
 let planner = RetrievalPlanner
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "???"),
 memoryStore: nil,
 attachmentStore: nil,
 workspaceURL: nil,
 fileProvider: nil
 )

 XCTAssertNil(decision.query)
 XCTAssertTrue(decision.artifacts.isEmpty)
 }

 func test_plan_nonQuestionClassification_skipsRetrieval() async throws {
 let sid = "planner-nonquestion-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }
 let attachmentStore = AttachmentStore(sessionId: sid)
 try await attachmentStore.ingest(makeAttachment(content: "Isaac likes relay"))

 let (memoryStore, root) = try makeMemoryStore
 defer { try? FileManager.default.removeItem(at: root) }
 try await memoryStore.writeFile(
 "user_profile.md",
 content: """
 ---
 name: User Profile
 description: user identity
 type: user
 ---

 Isaac likes relay.
 """
 )

 let planner = RetrievalPlanner
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "what's my name?", classification: .factRecallUnknown),
 memoryStore: memoryStore,
 attachmentStore: attachmentStore,
 workspaceURL: nil,
 fileProvider: nil
 )

 XCTAssertNil(decision.query)
 XCTAssertTrue(decision.artifacts.isEmpty)
 }

 func test_plan_mergeCaps_enforceGlobalArtifactAndTokenBudget() async throws {
 let sid = "planner-caps-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }
 let attachmentStore = AttachmentStore(sessionId: sid)
 try await attachmentStore.ingest(makeAttachment(
 content: Array(repeating: "reset keyword reset keyword filler.", count: 8).joined(separator: "\n"),
 chunkByteTarget: 48
 ))

 let (memoryStore, root) = try makeMemoryStore
 defer { try? FileManager.default.removeItem(at: root) }
 try await memoryStore.writeFile(
 "project_reset.md",
 content: """
 ---
 name: Reset project
 description: reset docs
 type: project
 ---

 reset keyword reset keyword reset keyword reset keyword
 """
 )
 try await memoryStore.writeFile(
 "reference_reset.md",
 content: """
 ---
 name: Reset reference
 description: reset docs
 type: reference
 ---

 reset keyword reset keyword reset keyword reset keyword
 """
 )

 let workspace = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayWorkspaceCaps-\(UUID().uuidString)", isDirectory: true)
 let provider = StubFileProvider(
 results: [
 FileSearchResult(path: workspace.appendingPathComponent("A.txt").path, displayName: "A.txt"),
 FileSearchResult(path: workspace.appendingPathComponent("B.txt").path, displayName: "B.txt"),
 ],
 fileData: [
 workspace.appendingPathComponent("A.txt").path: Data("reset keyword reset keyword".utf8),
 workspace.appendingPathComponent("B.txt").path: Data("reset keyword reset keyword".utf8),
 ]
 )

 let planner = RetrievalPlanner(
 maxTotalArtifacts: 2,
 maxInjectedTokens: 40
 )
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "how do I reset keyword flow?"),
 memoryStore: memoryStore,
 attachmentStore: attachmentStore,
 workspaceURL: workspace,
 fileProvider: provider
 )

 XCTAssertLessThanOrEqual(decision.artifacts.count, 2)
 XCTAssertLessThanOrEqual(decision.artifacts.reduce(0) { $0 + $1.artifact.tokenEstimate }, 40)
 }

 func test_plan_tieBreaksBySourcePriorityThenName() async throws {
 let sid = "planner-tiebreak-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }
 let attachmentStore = AttachmentStore(sessionId: sid)
 try await attachmentStore.ingest(makeAttachment(content: "alpha alpha alpha"))

 let (memoryStore, root) = try makeMemoryStore
 defer { try? FileManager.default.removeItem(at: root) }
 try await memoryStore.writeFile(
 "project_alpha.md",
 content: """
 ---
 name: Alpha Memory
 description: alpha alpha alpha
 type: project
 ---

 alpha alpha alpha
 """
 )

 let workspace = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayWorkspaceTie-\(UUID().uuidString)", isDirectory: true)
 let workspacePath = workspace.appendingPathComponent("Alpha.txt").path
 let provider = StubFileProvider(
 results: [FileSearchResult(path: workspacePath, displayName: "Alpha.txt")],
 fileData: [workspacePath: Data("alpha alpha alpha".utf8)]
 )

 let planner = RetrievalPlanner(maxAttachmentArtifacts: 1, maxMemoryArtifacts: 1, maxWorkspaceArtifacts: 1)
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "alpha"),
 memoryStore: memoryStore,
 attachmentStore: attachmentStore,
 workspaceURL: workspace,
 fileProvider: provider
 )

 XCTAssertEqual(decision.artifacts.map { $0.artifact.kind }, [.attachment, .memory, .workspace])
 }

 func test_loadRetrievalDocuments_parsesFrontmatterAndFallsBackSafely() async throws {
 let (store, root) = try makeMemoryStore
 defer { try? FileManager.default.removeItem(at: root) }

 try await store.writeFile(
 "user_profile.md",
 content: """
 ---
 name: Isaac
 description: identity
 type: user
 ---

 body text
 """
 )
 try await store.writeFile("reference_links.md", content: "plain body")

 let docs = await store.loadRetrievalDocuments

 XCTAssertEqual(docs.first?.displayName, "Isaac")
 XCTAssertEqual(docs.first?.description, "identity")
 XCTAssertEqual(docs.first?.type, "user")
 XCTAssertEqual(docs.first?.body, "body text")
 XCTAssertEqual(docs.last?.displayName, "reference links")
 }

 func test_workspaceCollector_skipsUnreadableBinaryFiles() async {
 let workspace = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayWorkspaceBinary-\(UUID().uuidString)", isDirectory: true)
 let binaryPath = workspace.appendingPathComponent("Blob.bin").path
 let provider = StubFileProvider(
 results: [FileSearchResult(path: binaryPath, displayName: "Blob.bin")],
 fileData: [binaryPath: Data([0xFF, 0x00, 0xFE, 0xFF])]
 )

 let planner = RetrievalPlanner
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "alpha"),
 memoryStore: nil,
 attachmentStore: nil,
 workspaceURL: workspace,
 fileProvider: provider
 )

 XCTAssertTrue(decision.artifacts.isEmpty)
 }

 func test_workspaceArtifacts_useRelativeIds() async {
 let workspace = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayWorkspaceRelative-\(UUID().uuidString)", isDirectory: true)
 let nestedPath = workspace.appendingPathComponent("Docs/Guide.txt").path
 let provider = StubFileProvider(
 results: [FileSearchResult(path: nestedPath, displayName: "Guide.txt")],
 fileData: [nestedPath: Data("reset reset reset".utf8)]
 )

 let planner = RetrievalPlanner
 let decision = await planner.plan(
 analysis: makeAnalysis(text: "reset"),
 memoryStore: nil,
 attachmentStore: nil,
 workspaceURL: workspace,
 fileProvider: provider
 )

 XCTAssertEqual(decision.artifacts.first?.artifact.id, "Docs/Guide.txt")
 }
}
