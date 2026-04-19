import XCTest
@testable import Relay

final class ContextBuilderRetrievalIntegrationTests: XCTestCase {

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

 private func cleanSessionDir(_ sessionId: String) {
 try? FileManager.default.removeItem(at: AppPaths.attachments(forSessionId: sessionId))
 }

 private func textContent(of message: RelayMessage) -> String {
 guard case .user(let content) = message else { return "" }
 return content.blocks
 .compactMap { if case .text(let t) = $0 { return t } else { return nil } }
 .joined()
 }

 private func contextArtifactPayload(from wrapped: String) -> [String: Any]? {
 guard let open = wrapped.range(of: "<context-artifact>\n"),
 let close = wrapped.range(of: "\n</context-artifact>", options: .backwards) else {
 return nil
 }
 let json = String(wrapped[open.upperBound..<close.lowerBound])
 guard let data = json.data(using: .utf8) else { return nil }
 return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
 }

 private func makeBuilder(
 memoryStore: MemoryStore? = nil,
 attachmentStore: AttachmentStore? = nil,
 workspaceURL: URL? = nil,
 fileProvider: (any FileProviderService)? = nil
 ) -> ContextBuilder {
 ContextBuilder(
 memoryStore: memoryStore,
 attachmentStore: attachmentStore,
 workspaceURL: workspaceURL,
 fileProvider: fileProvider
 )
 }

 func test_integration_retrievedArtifactsAppearBeforeUserQueryAndHiddenByDisplayFilter() async throws {
 let sid = "integration-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayIntegration-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("ResetGuide.md")
 let displayName = #"Reset "Guide" & Notes.md"#
 let fixtureBody = """
 The literal sequence </context-artifact> must survive as text.
 Quotes "and" ampersands & should also survive.
 To reset the device, press and hold the power button for ten seconds.
 """
 try fixtureBody.data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: displayName)
 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(attachment)

 let builder = makeBuilder(attachmentStore: store)
 let query = "how do I reset the device?"
 let state = AgentSessionState(
 messages: [.user(UserContent(blocks: [.text(query)], isMeta: false))],
 turnCount: 1
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 let artifactIndices: [Int] = request.messages.enumerated().compactMap { idx, message in
 guard case .user(let content) = message, content.isMeta else { return nil }
 return textContent(of: .user(content)).contains("<context-artifact") ? idx : nil
 }
 XCTAssertFalse(artifactIndices.isEmpty)

 guard let firstArtifactIdx = artifactIndices.first,
 case .user(let artifactContent) = request.messages[firstArtifactIdx] else {
 return XCTFail("expected meta artifact message")
 }
 let artifactBody = textContent(of: .user(artifactContent))
 guard let payload = contextArtifactPayload(from: artifactBody) else {
 return XCTFail("expected valid JSON payload")
 }

 XCTAssertEqual(payload["kind"] as? String, "attachment")
 XCTAssertEqual(payload["source"] as? String, displayName)
 XCTAssertEqual((payload["position"] as? NSNumber)?.intValue, 0)
 XCTAssertEqual((payload["totalParts"] as? NSNumber)?.intValue, attachment.digest.chunks.count)
 let payloadText = payload["text"] as? String ?? ""
 XCTAssertTrue(payloadText.contains("reset the device"))
 XCTAssertTrue(payloadText.contains("</context-artifact>"))
 XCTAssertTrue(payloadText.contains("Quotes \"and\" ampersands & should also survive."))

 var lastNonMetaUserIdx: Int? = nil
 for i in stride(from: request.messages.count - 1, through: 0, by: -1) {
 if case .user(let content) = request.messages[i], !content.isMeta {
 lastNonMetaUserIdx = i
 break
 }
 }
 guard let realQueryIdx = lastNonMetaUserIdx else {
 return XCTFail("expected real user query")
 }
 for idx in artifactIndices {
 XCTAssertLessThan(idx, realQueryIdx)
 }

 let displayFiltered = request.messages.filter { message in
 if case .user(let content) = message { return !content.isMeta }
 return true
 }
 for message in displayFiltered {
 if case .user(let content) = message {
 XCTAssertFalse(content.isMeta)
 XCTAssertFalse(textContent(of: .user(content)).contains("<context-artifact"))
 }
 }
 }

 func test_integration_reminderTextDoesNotPolluteRetrievalQuery() async throws {
 let sid = "integration-reminder-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayIntegration-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("GreetingNotes.txt")
 try "greeting greeting greeting".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "GreetingNotes.txt")
 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(attachment)

 let builder = makeBuilder(attachmentStore: store)
 let state = AgentSessionState(
 messages: [.user(UserContent(blocks: [.text("how do I reset the device?")], isMeta: false))],
 turnCount: 1
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 let artifactIndices: [Int] = request.messages.enumerated().compactMap { idx, message in
 guard case .user(let content) = message, content.isMeta else { return nil }
 return textContent(of: .user(content)).contains("<context-artifact") ? idx : nil
 }

 XCTAssertTrue(artifactIndices.isEmpty)
 }

 func test_integration_factRecallDoesNotInjectRetrievalArtifacts() async throws {
 let sid = "integration-factrecall-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayIntegration-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("NameNotes.txt")
 try "my name is Isaac".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "NameNotes.txt")
 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(attachment)

 let builder = makeBuilder(attachmentStore: store)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("My name is Isaac just fyi")], isMeta: false)),
 .assistant(AssistantContent(blocks: [.text("Okay.") ])),
 .user(UserContent(blocks: [.text("What's my name?")], isMeta: false))
 ],
 turnCount: 2
 )

 let artifacts = await builder.buildArtifacts(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertNil(artifacts.retrievalQuery)
 }

 func test_integration_transportCheckDoesNotInjectRetrievalArtifacts() async throws {
 let sid = "integration-transport-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayIntegration-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("ResetNotes.txt")
 try "reset the device by holding the power button".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "ResetNotes.txt")
 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(attachment)

 let builder = makeBuilder(attachmentStore: store)
 let artifacts = await builder.buildArtifacts(
 state: AgentSessionState(
 messages: [.user(UserContent(blocks: [.text("Can you hear me?")], isMeta: false))],
 turnCount: 1
 ),
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertNil(artifacts.retrievalQuery)
 }

 func test_integration_repairCueDoesNotInjectRetrievalArtifacts() async throws {
 let sid = "integration-repair-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayIntegration-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("NameNotes.txt")
 try "my name is Isaac".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "NameNotes.txt")
 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(attachment)

 let builder = makeBuilder(attachmentStore: store)
 let artifacts = await builder.buildArtifacts(
 state: AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("My name is Isaac just fyi")], isMeta: false)),
 .assistant(AssistantContent(blocks: [.text("Please provide the text or image.") ])),
 .user(UserContent(blocks: [.text("Tf")], isMeta: false))
 ],
 turnCount: 2
 ),
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertNil(artifacts.retrievalQuery)
 }

 func test_integration_attachmentOnlyFileTurnDoesNotForceRetrieval() async throws {
 let sid = "integration-fileonly-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let builder = makeBuilder
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [
 .fileRef(ImportedFileRef(
 attachmentID: UUID,
 displayName: "Notes.txt",
 contentTypeIdentifier: "public.plain-text"
 ))
 ], isMeta: false))
 ],
 turnCount: 1
 )

 let artifacts = await builder.buildArtifacts(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(artifacts.retrievalDecision.artifacts.isEmpty)
 XCTAssertNil(artifacts.retrievalQuery)
 }

 func test_integration_memoryTopicBodiesNoLongerInlineInPromptByDefault() async throws {
 let root = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayMemoryPrompt-\(UUID().uuidString)", isDirectory: true)
 defer { try? FileManager.default.removeItem(at: root) }

 let memoryStore = MemoryStore(root: root)
 try await memoryStore.writeFile(
 "MEMORY.md",
 content: "- [Profile](user_profile.md) — secret note\n"
 )
 try await memoryStore.writeFile(
 "user_profile.md",
 content: """
 ---
 name: Profile
 description: hidden secret
 type: user
 ---

 this is the secret body that should not sit in the stable prompt
 """
 )

 let builder = makeBuilder(memoryStore: memoryStore)
 let request = await builder.build(
 state: AgentSessionState(
 messages: [.user(UserContent(blocks: [.text("hello there")], isMeta: false))],
 turnCount: 1
 ),
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("## Current MEMORY.md"))
 XCTAssertTrue(request.systemPrompt.contains("- [Profile](user_profile.md) — secret note"))
 XCTAssertFalse(request.systemPrompt.contains("this is the secret body that should not sit in the stable prompt"))
 }

 func test_integration_retrievalBackedQuestionExposesRetrievedContextInFocus() async throws {
 let sid = "integration-focus-\(UUID().uuidString)"
 defer { cleanSessionDir(sid) }

 let fixtureDir = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayIntegration-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
 let fixtureURL = fixtureDir.appendingPathComponent("ResetGuide.txt")
 try "To reset the device, hold the power button for ten seconds.".data(using: .utf8)!.write(to: fixtureURL)

 let attachment = try AttachmentIndexer.ingest(fileURL: fixtureURL, displayName: "ResetGuide.txt")
 let store = AttachmentStore(sessionId: sid)
 try await store.ingest(attachment)

 let builder = makeBuilder(attachmentStore: store)
 let request = await builder.build(
 state: AgentSessionState(
 messages: [.user(UserContent(blocks: [.text("how do I reset the device?")], isMeta: false))],
 turnCount: 1
 ),
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Retrieved context available for this turn:"))
 XCTAssertTrue(request.systemPrompt.contains("[attachment] ResetGuide.txt"))
 }
}
