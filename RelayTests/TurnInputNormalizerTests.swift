import XCTest
@testable import Relay

/// Pure-function tests for the Module 02 ingress contract and the existing
/// `AgentSessionState.derivedTurnCount(from:)` regression harness.
final class TurnInputNormalizerTests: XCTestCase {

 func test_normalize_text_only_turn_producesMatchingTranscriptAndModel() async throws {
 let normalizer = makeNormalizer
 let normalized = try await normalizer.normalize(
 TurnEnvelope(
 kind: .text,
 visibleText: "hi",
 source: .composerText
 )
 )

 assertSingleTextUserMessage(normalized.transcriptMessage, expected: "hi")
 assertSingleTextUserMessage(normalized.modelMessage, expected: "hi")
 XCTAssertTrue(normalized.pendingFileIngestions.isEmpty)
 }

 func test_normalize_voice_turn_preservesTranscriptAndAudioRef() async throws {
 let normalizer = makeNormalizer
 let audioURL = URL(fileURLWithPath: "/tmp/fake.wav")
 let normalized = try await normalizer.normalize(
 TurnEnvelope(
 kind: .voice,
 visibleText: "hello",
 audioRef: audioURL,
 source: .composerVoice
 )
 )

 guard case .user(let transcriptContent) = normalized.transcriptMessage else {
 return XCTFail("expected user transcript")
 }
 XCTAssertEqual(transcriptContent.blocks.count, 2)
 guard case .text(let transcriptText) = transcriptContent.blocks[0] else {
 return XCTFail("expected text block first")
 }
 XCTAssertEqual(transcriptText, "hello")
 guard case .audioRef(let transcriptAudio) = transcriptContent.blocks[1] else {
 return XCTFail("expected audioRef second")
 }
 XCTAssertEqual(transcriptAudio, audioURL)

 guard case .user(let modelContent) = normalized.modelMessage else {
 return XCTFail("expected user model message")
 }
 XCTAssertEqual(modelContent.blocks.count, 2)
 guard case .text(let modelText) = modelContent.blocks[0] else {
 return XCTFail("expected model text block first")
 }
 XCTAssertEqual(modelText, "hello")
 guard case .audioRef(let modelAudio) = modelContent.blocks[1] else {
 return XCTFail("expected model audioRef second")
 }
 XCTAssertEqual(modelAudio, audioURL)
 }

 func test_normalize_image_turn_copiesStableImageURL() async throws {
 let mediaRoot = makeTempDir
 defer { try? FileManager.default.removeItem(at: mediaRoot) }

 let sourceImage = mediaRoot.appendingPathComponent("source.jpg")
 try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: sourceImage)

 let normalizer = makeNormalizer(mediaRoot: mediaRoot.appendingPathComponent("session-media", isDirectory: true))
 let normalized = try await normalizer.normalize(
 TurnEnvelope(
 kind: .image,
 imageRefs: [sourceImage],
 source: .composerImage
 )
 )

 guard case .user(let transcriptContent) = normalized.transcriptMessage else {
 return XCTFail("expected user transcript")
 }
 guard case .image(let transcriptURL) = transcriptContent.blocks[0] else {
 return XCTFail("expected transcript image block")
 }
 XCTAssertNotEqual(transcriptURL, sourceImage)
 XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))

 guard case .user(let modelContent) = normalized.modelMessage else {
 return XCTFail("expected user model")
 }
 guard case .image(let modelURL) = modelContent.blocks[0] else {
 return XCTFail("expected model image block")
 }
 XCTAssertEqual(modelURL, transcriptURL)
 }

 func test_normalize_file_only_turn_transcriptKeepsFileRef_modelGetsAcknowledgementPreamble() async throws {
 let normalizer = makeNormalizer
 let file = PendingFileIngestion(
 attachmentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(),
 sourceURL: URL(fileURLWithPath: "/tmp/guide.md"),
 displayName: "Guide.md",
 contentTypeIdentifier: "public.plain-text"
 )
 let normalized = try await normalizer.normalize(
 TurnEnvelope(
 kind: .file,
 fileRefs: [file],
 source: .composerFile
 )
 )

 guard case .user(let transcriptContent) = normalized.transcriptMessage else {
 return XCTFail("expected user transcript")
 }
 XCTAssertEqual(transcriptContent.blocks.count, 1)
 guard case .fileRef(let fileRef) = transcriptContent.blocks[0] else {
 return XCTFail("expected fileRef transcript block")
 }
 XCTAssertEqual(fileRef.attachmentID, file.attachmentID)
 XCTAssertEqual(fileRef.displayName, "Guide.md")

 guard case .user(let modelContent) = normalized.modelMessage else {
 return XCTFail("expected user model")
 }
 XCTAssertEqual(modelContent.blocks.count, 1)
 guard case .text(let preamble) = modelContent.blocks[0] else {
 return XCTFail("expected model preamble text")
 }
 XCTAssertTrue(preamble.contains("User attached file(s): Guide.md"))
 XCTAssertTrue(preamble.contains("ask what they want analyzed"))
 XCTAssertEqual(normalized.pendingFileIngestions, [file])
 }

 func test_normalize_textPlusFile_turn_prependsAttachedFilesPreamble() async throws {
 let normalizer = makeNormalizer
 let file = PendingFileIngestion(
 sourceURL: URL(fileURLWithPath: "/tmp/notes.json"),
 displayName: "notes.json",
 contentTypeIdentifier: "public.json"
 )
 let normalized = try await normalizer.normalize(
 TurnEnvelope(
 kind: .mixed,
 visibleText: "Summarize the important parts.",
 fileRefs: [file],
 source: .composerFile
 )
 )

 guard case .user(let transcriptContent) = normalized.transcriptMessage else {
 return XCTFail("expected user transcript")
 }
 XCTAssertEqual(transcriptContent.blocks.count, 2)
 guard case .text(let visibleText) = transcriptContent.blocks[0] else {
 return XCTFail("expected visible text first")
 }
 XCTAssertEqual(visibleText, "Summarize the important parts.")
 guard case .fileRef = transcriptContent.blocks[1] else {
 return XCTFail("expected fileRef second")
 }

 guard case .user(let modelContent) = normalized.modelMessage else {
 return XCTFail("expected user model")
 }
 XCTAssertEqual(modelContent.blocks.count, 1)
 guard case .text(let modelText) = modelContent.blocks[0] else {
 return XCTFail("expected model text")
 }
 XCTAssertTrue(modelText.contains("Attached files: notes.json."))
 XCTAssertTrue(modelText.contains("Summarize the important parts."))
 }

 func test_normalize_mixed_turn_keepsStableOrdering() async throws {
 let mediaRoot = makeTempDir
 defer { try? FileManager.default.removeItem(at: mediaRoot) }

 let sourceImage = mediaRoot.appendingPathComponent("draft.png")
 try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceImage)

 let normalizer = makeNormalizer(mediaRoot: mediaRoot.appendingPathComponent("session-media", isDirectory: true))
 let fileA = PendingFileIngestion(
 sourceURL: URL(fileURLWithPath: "/tmp/a.md"),
 displayName: "a.md",
 contentTypeIdentifier: "public.plain-text"
 )
 let fileB = PendingFileIngestion(
 sourceURL: URL(fileURLWithPath: "/tmp/b.csv"),
 displayName: "b.csv",
 contentTypeIdentifier: "public.comma-separated-values-text"
 )
 let normalized = try await normalizer.normalize(
 TurnEnvelope(
 kind: .mixed,
 visibleText: "Compare these.",
 audioRef: URL(fileURLWithPath: "/tmp/fake.wav"),
 imageRefs: [sourceImage],
 fileRefs: [fileA, fileB],
 source: .composerFile
 )
 )

 guard case .user(let transcriptContent) = normalized.transcriptMessage else {
 return XCTFail("expected user transcript")
 }
 XCTAssertEqual(transcriptContent.blocks.count, 5)
 guard
 case .text = transcriptContent.blocks[0],
 case .audioRef = transcriptContent.blocks[1],
 case .image = transcriptContent.blocks[2],
 case .fileRef(let firstFile) = transcriptContent.blocks[3],
 case .fileRef(let secondFile) = transcriptContent.blocks[4]
 else {
 return XCTFail("expected [text, audioRef, image, fileRef, fileRef] ordering")
 }
 XCTAssertEqual(firstFile.displayName, "a.md")
 XCTAssertEqual(secondFile.displayName, "b.csv")

 guard case .user(let modelContent) = normalized.modelMessage else {
 return XCTFail("expected user model")
 }
 XCTAssertEqual(modelContent.blocks.count, 3)
 guard
 case .text(let modelText) = modelContent.blocks[0],
 case .audioRef = modelContent.blocks[1],
 case .image = modelContent.blocks[2]
 else {
 return XCTFail("expected [text, audioRef, image] ordering")
 }
 XCTAssertTrue(modelText.contains("Attached files: a.md, b.csv."))
 XCTAssertEqual(normalized.pendingFileIngestions, [fileA, fileB])
 }

 func test_normalize_prebuilt_message_passesThroughUnchanged() async throws {
 let normalizer = makeNormalizer
 let prebuilt = RelayMessage.user(UserContent(
 blocks: [.text("already built")],
 isMeta: true
 ))
 let normalized = try await normalizer.normalize(
 TurnEnvelope(
 kind: .prebuilt,
 source: .programmatic,
 prebuiltMessage: prebuilt
 )
 )

 guard case .user(let transcriptContent) = normalized.transcriptMessage else {
 return XCTFail("expected user transcript")
 }
 XCTAssertTrue(transcriptContent.isMeta)
 guard case .user(let modelContent) = normalized.modelMessage else {
 return XCTFail("expected user model")
 }
 XCTAssertTrue(modelContent.isMeta)
 XCTAssertTrue(normalized.pendingFileIngestions.isEmpty)
 }

 func test_projectMessageForModel_reconstructsFilePreambleFromTranscript() {
 let message = RelayMessage.user(UserContent(blocks: [
 .text("Summarize this."),
 .fileRef(ImportedFileRef(
 attachmentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(),
 displayName: "Guide.md",
 contentTypeIdentifier: "public.plain-text"
 )),
 ]))

 let projected = TurnIngressNormalizer.projectMessageForModel(message)
 guard case .user(let content) = projected else {
 return XCTFail("expected user message")
 }
 XCTAssertEqual(content.blocks.count, 1)
 guard case .text(let text) = content.blocks[0] else {
 return XCTFail("expected projected text block")
 }
 XCTAssertTrue(text.contains("Attached files: Guide.md."))
 XCTAssertTrue(text.contains("Summarize this."))
 }

 func test_projectMessageForModel_fileOnlyTranscriptTurnGetsAcknowledgementPreamble() {
 let message = RelayMessage.user(UserContent(blocks: [
 .fileRef(ImportedFileRef(
 attachmentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-FFFFFFFFFFFF") ?? UUID(),
 displayName: "Notes.txt",
 contentTypeIdentifier: "public.plain-text"
 )),
 ]))

 let projected = TurnIngressNormalizer.projectMessageForModel(message)
 guard case .user(let content) = projected else {
 return XCTFail("expected user message")
 }
 XCTAssertEqual(content.blocks.count, 1)
 guard case .text(let text) = content.blocks[0] else {
 return XCTFail("expected projected acknowledgement preamble")
 }
 XCTAssertTrue(text.contains("User attached file(s): Notes.txt."))
 XCTAssertTrue(text.contains("ask what they want analyzed"))
 }

 func test_projectMessageForModel_preservesTrailingSystemReminderBlock() {
 let reminder = """
 <system-reminder>
 Current user message: "Summarize this."
 </system-reminder>
 """
 let message = RelayMessage.user(UserContent(blocks: [
 .text("Summarize this."),
 .fileRef(ImportedFileRef(
 attachmentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111") ?? UUID(),
 displayName: "Guide.md",
 contentTypeIdentifier: "public.plain-text"
 )),
 .text(reminder),
 ]))

 let projected = TurnIngressNormalizer.projectMessageForModel(message)
 guard case .user(let content) = projected else {
 return XCTFail("expected user message")
 }
 XCTAssertEqual(content.blocks.count, 2)
 guard case .text(let preamble) = content.blocks[0] else {
 return XCTFail("expected projected text block")
 }
 XCTAssertTrue(preamble.contains("Attached files: Guide.md."))
 guard case .text(let preservedReminder) = content.blocks[1] else {
 return XCTFail("expected preserved reminder block")
 }
 XCTAssertEqual(preservedReminder, reminder)
 }

 func test_prepareTurn_rejectsUnsupportedFileBeforeExecution() async throws {
 let tempDir = makeTempDir
 defer { try? FileManager.default.removeItem(at: tempDir) }

 let fileURL = tempDir.appendingPathComponent("report.pdf")
 try Data("fake".utf8).write(to: fileURL)

 let store = AttachmentStore(sessionId: "unsupported-file-test")
 let core = AgentCore(
 host: CactusModelHost(modelPath: "/dev/null"),
 config: .init(attachmentStore: store),
 transcriptSessionId: "unsupported-file-test"
 )

 let envelope = TurnEnvelope(
 kind: .file,
 fileRefs: [
 PendingFileIngestion(
 sourceURL: fileURL,
 displayName: "report.pdf",
 contentTypeIdentifier: "com.adobe.pdf"
 )
 ],
 source: .composerFile
 )

 await XCTAssertThrowsErrorAsync(try await core.prepareTurn(envelope)) { error in
 XCTAssertEqual(error as? TurnIngressError, .unsupportedFileType("report.pdf"))
 }
 let persisted = await store.all
 XCTAssertTrue(persisted.isEmpty)
 }

 func test_prepareTurn_rejectsOversizedFileBeforeExecution() async throws {
 let tempDir = makeTempDir
 defer { try? FileManager.default.removeItem(at: tempDir) }

 let fileURL = tempDir.appendingPathComponent("large.txt")
 let oversized = Data(repeating: 0x61, count: AttachmentIndexer.maxFileBytes + 1)
 try oversized.write(to: fileURL)

 let store = AttachmentStore(sessionId: "oversized-file-test")
 let core = AgentCore(
 host: CactusModelHost(modelPath: "/dev/null"),
 config: .init(attachmentStore: store),
 transcriptSessionId: "oversized-file-test"
 )

 let envelope = TurnEnvelope(
 kind: .file,
 fileRefs: [
 PendingFileIngestion(
 sourceURL: fileURL,
 displayName: "large.txt",
 contentTypeIdentifier: "public.plain-text"
 )
 ],
 source: .composerFile
 )

 await XCTAssertThrowsErrorAsync(try await core.prepareTurn(envelope)) { error in
 XCTAssertEqual(error as? AttachmentError, .fileTooLarge)
 }
 let persisted = await store.all
 XCTAssertTrue(persisted.isEmpty)
 }

 func test_prepareTurn_rejectsMixedValidInvalidBatchWithoutPartialIngest() async throws {
 let tempDir = makeTempDir
 defer { try? FileManager.default.removeItem(at: tempDir) }

 let validURL = tempDir.appendingPathComponent("good.txt")
 let invalidURL = tempDir.appendingPathComponent("bad.pdf")
 try Data("hello".utf8).write(to: validURL)
 try Data("fake".utf8).write(to: invalidURL)

 let store = AttachmentStore(sessionId: "mixed-batch-test")
 let core = AgentCore(
 host: CactusModelHost(modelPath: "/dev/null"),
 config: .init(attachmentStore: store),
 transcriptSessionId: "mixed-batch-test"
 )

 let envelope = TurnEnvelope(
 kind: .mixed,
 visibleText: "Summarize these.",
 fileRefs: [
 PendingFileIngestion(
 sourceURL: validURL,
 displayName: "good.txt",
 contentTypeIdentifier: "public.plain-text"
 ),
 PendingFileIngestion(
 sourceURL: invalidURL,
 displayName: "bad.pdf",
 contentTypeIdentifier: "com.adobe.pdf"
 )
 ],
 source: .composerFile
 )

 await XCTAssertThrowsErrorAsync(try await core.prepareTurn(envelope)) { error in
 XCTAssertEqual(error as? TurnIngressError, .unsupportedFileType("bad.pdf"))
 }
 let persisted = await store.all
 XCTAssertTrue(persisted.isEmpty)
 }

 func test_draftWithPendingAttachments_disablesVoiceEntry() {
 var draft = ComposerDraft
 XCTAssertTrue(draft.isVoiceAllowed)

 draft.pendingFiles = [
 PendingFileIngestion(
 sourceURL: URL(fileURLWithPath: "/tmp/notes.txt"),
 displayName: "notes.txt",
 contentTypeIdentifier: "public.plain-text"
 )
 ]
 XCTAssertFalse(draft.isVoiceAllowed)

 draft.pendingFiles = []
 draft.pendingImages = [
 PendingDraftImage(
 stagedURL: URL(fileURLWithPath: "/tmp/image.jpg"),
 displayName: "image.jpg"
 )
 ]
 XCTAssertFalse(draft.isVoiceAllowed)
 }

 func test_oldTranscriptDecodesWithoutFileRefs() throws {
 let original = RelayMessage.user(UserContent(blocks: [.text("hi")]))
 let data = try JSONEncoder.encode(original)
 let decoded = try JSONDecoder.decode(RelayMessage.self, from: data)

 guard case .user(let content) = decoded else {
 return XCTFail("expected decoded user message")
 }
 XCTAssertEqual(content.blocks.count, 1)
 guard case .text(let text) = content.blocks[0] else {
 return XCTFail("expected decoded text block")
 }
 XCTAssertEqual(text, "hi")
 }

 // MARK: - AgentSessionState.derivedTurnCount

 func test_derivedTurnCount_skipsMetaUserMessages() {
 let history: [RelayMessage] = [
 .user(UserContent(blocks: [.text("first")])),
 .assistant(AssistantContent(blocks: [.text("r1")])),
 .user(UserContent(blocks: [.text("<system-reminder>\nmeta\n</system-reminder>")], isMeta: true)),
 .user(UserContent(blocks: [.text("second")])),
 .assistant(AssistantContent(blocks: [.text("r2")])),
 .user(UserContent(blocks: [.text("<system-reminder>\nmore meta\n</system-reminder>")], isMeta: true)),
 .user(UserContent(blocks: [.text("third")])),
 .assistant(AssistantContent(blocks: [.text("r3")])),
 ]

 let count = AgentSessionState.derivedTurnCount(from: history)
 XCTAssertEqual(count, 3)
 }

 func test_derivedTurnCount_empty_isZero() {
 XCTAssertEqual(AgentSessionState.derivedTurnCount(from: []), 0)
 }

 func test_derivedTurnCount_noUserMessages_isZero() {
 let history: [RelayMessage] = [
 .assistant(AssistantContent(blocks: [.text("hi")])),
 .toolResult([]),
 ]
 XCTAssertEqual(AgentSessionState.derivedTurnCount(from: history), 0)
 }

 func test_emptyState_hasNoMessagesAndZeroTurnCount() {
 let empty = AgentSessionState.empty
 XCTAssertTrue(empty.messages.isEmpty)
 XCTAssertEqual(empty.turnCount, 0)
 }

 // MARK: - Helpers

 private func makeNormalizer(mediaRoot: URL? = nil) -> TurnIngressNormalizer {
 TurnIngressNormalizer(
 sessionId: "test-session",
 mediaRootOverride: mediaRoot
 )
 }

 private func makeTempDir() -> URL {
 let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
 try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
 return url
 }

 private func assertSingleTextUserMessage(_ message: RelayMessage, expected: String, file: StaticString = #filePath, line: UInt = #line) {
 guard case .user(let content) = message else {
 return XCTFail("expected user message", file: file, line: line)
 }
 XCTAssertEqual(content.blocks.count, 1, file: file, line: line)
 guard case .text(let text) = content.blocks[0] else {
 return XCTFail("expected single text block", file: file, line: line)
 }
 XCTAssertEqual(text, expected, file: file, line: line)
 }

 private func XCTAssertThrowsErrorAsync<T>(
 _ expression: @autoclosure  async throws -> T,
 _ verify: (Error) -> Void,
 file: StaticString = #filePath,
 line: UInt = #line
 ) async {
 do {
 _ = try await expression
 XCTFail("expected error", file: file, line: line)
 } catch {
 verify(error)
 }
 }
}
