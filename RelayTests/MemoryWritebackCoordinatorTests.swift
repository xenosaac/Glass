import XCTest
@testable import Relay

/// tests for `MemoryWritebackCoordinator`. The coordinator is
/// a thin extraction of the former
/// `ChatViewModel.persistMemoryForCompletedTurn(...)` body; these
/// tests lock that the watermark-update behavior matches what the
/// view-model used to do inline, and that a missing session metadata
/// entry results in a no-op (covers the edge case where the session
/// was deleted between send and writeback).
final class MemoryWritebackCoordinatorTests: XCTestCase {

 // MARK: - Helpers

 private func makeTempSessionIndex() -> SessionIndex {
 let tmp = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
 try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
 return SessionIndex(baseDir: tmp)
 }

 private func makeUserMessage(_ text: String) -> RelayMessage {
 .user(UserContent(blocks: [.text(text)]))
 }

 private func makeAssistantMessage(_ text: String) -> RelayMessage {
 .assistant(AssistantContent(blocks: [.text(text)]))
 }

 // MARK: - Test 1: watermark update

 func test_afterTurn_updatesWatermarkToCurrentMessageCount() async throws {
 let index = makeTempSessionIndex
 let session = try await index.create(workspace: nil)

 // Bump messageCount via `recordMessage` a few times so
 // messageCount > lastIndexedMessageCount prior to the call.
 try await index.recordMessage(sessionId: session.id, firstUserText: "hi")
 try await index.recordMessage(sessionId: session.id)
 try await index.recordMessage(sessionId: session.id)

 guard let pre = await index.get(session.id) else {
 return XCTFail("expected session to exist pre-call")
 }
 XCTAssertEqual(pre.messageCount, 3)
 XCTAssertNil(pre.lastIndexedMessageCount, "baseline: watermark not yet set")

 let coordinator = MemoryWritebackCoordinator(sessionIndex: index)
 await coordinator.afterTurn(
 sessionId: session.id,
 userMessage: makeUserMessage("hi"),
 assistantMessage: makeAssistantMessage("hello"),
 wasVoiceTurn: false
 )

 guard let post = await index.get(session.id) else {
 return XCTFail("expected session to exist post-call")
 }
 XCTAssertEqual(post.lastIndexedMessageCount, post.messageCount,
 "watermark must advance to current messageCount")
 XCTAssertEqual(post.lastIndexedMessageCount, 3)
 }

 // MARK: - Test 2: no-op when metadata missing

 func test_afterTurn_isNoOpWhenMetadataMissing() async {
 let index = makeTempSessionIndex
 let coordinator = MemoryWritebackCoordinator(sessionIndex: index)

 let unknownId = "no-such-session-\(UUID().uuidString)"

 // Must not throw, must not crash, must not modify the index.
 await coordinator.afterTurn(
 sessionId: unknownId,
 userMessage: makeUserMessage("hi"),
 assistantMessage: makeAssistantMessage("hello"),
 wasVoiceTurn: false
 )

 let missing = await index.get(unknownId)
 XCTAssertNil(missing, "missing session must not be created by the coordinator")
 }

 // MARK: - Round-5 deterministic writeback

 private func makeTempMemoryStore() -> MemoryStore {
 let tmp = FileManager.default.temporaryDirectory
 .appendingPathComponent("RelayMemoryWritebackTests-\(UUID().uuidString)", isDirectory: true)
 try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
 return MemoryStore(root: tmp)
 }

 func test_extractCanonicalFact_matchesMyNameIs() {
 let fact = MemoryWritebackCoordinator.extractCanonicalFact(from: "My name is Isaac")
 XCTAssertNotNil(fact)
 XCTAssertEqual(fact?.fileName, "user_name.md")
 XCTAssertTrue(fact?.content.contains("Name: Isaac") ?? false)
 }

 func test_extractCanonicalFact_matchesIAm() {
 let fact = MemoryWritebackCoordinator.extractCanonicalFact(from: "I am Isaac")
 XCTAssertEqual(fact?.fileName, "user_name.md")
 XCTAssertTrue(fact?.content.contains("Name: Isaac") ?? false)
 }

 func test_extractCanonicalFact_matchesMyNameIsWithTrailingPunctuation() {
 let fact = MemoryWritebackCoordinator.extractCanonicalFact(from: "My name is Isaac.")
 XCTAssertEqual(fact?.fileName, "user_name.md")
 XCTAssertTrue(fact?.content.contains("Name: Isaac") ?? false)
 }

 // stop-on-conjunction in extractAlphaTokens.
 // Pre-hotfix, "My name is Isaac and I'm building..." was extracted as
 // "Isaac and I'm" (3 alpha tokens). Post-hotfix it stops at "and".

 func test_extractCanonicalFact_stopsAtAndConjunction() {
 let fact = MemoryWritebackCoordinator.extractCanonicalFact(
 from: "My name is Isaac and I'm building a voice agent"
 )
 XCTAssertEqual(fact?.fileName, "user_name.md")
 XCTAssertTrue(
 fact?.content.contains("Name: Isaac\n") ?? false,
 "expected just 'Isaac' in body; got: \(fact?.content ?? "nil")"
 )
 XCTAssertFalse(fact?.content.contains("and") ?? true,
 "must not capture conjunction 'and'")
 XCTAssertFalse(fact?.content.contains("I'm") ?? true,
 "must not capture pronoun 'I'm' after stopword")
 }

 func test_extractCanonicalFact_keepsMultiTokenName() {
 // Regression: real multi-word names must still be captured.
 let fact = MemoryWritebackCoordinator.extractCanonicalFact(
 from: "My name is John Doe Jr"
 )
 XCTAssertTrue(
 fact?.content.contains("Name: John Doe Jr") ?? false,
 "expected full multi-token name; got: \(fact?.content ?? "nil")"
 )
 }

 func test_extractCanonicalFact_stopsAtWhoConjunction() {
 let fact = MemoryWritebackCoordinator.extractCanonicalFact(
 from: "I am Bob who is a designer"
 )
 XCTAssertTrue(
 fact?.content.contains("Name: Bob") ?? false,
 "expected just 'Bob'; got: \(fact?.content ?? "nil")"
 )
 XCTAssertFalse(fact?.content.contains("designer") ?? true)
 }

 func test_extractCanonicalFact_doesNotMatchArbitraryDeclarative() {
 // "My favorite color is blue" is a declarative fact but not in the
 // canonical pattern set — coordinator must not write it.
 XCTAssertNil(MemoryWritebackCoordinator.extractCanonicalFact(from: "My favorite color is blue"))
 }

 func test_extractCanonicalFact_doesNotMatchNonDeclarative() {
 XCTAssertNil(MemoryWritebackCoordinator.extractCanonicalFact(from: "What's my name?"))
 XCTAssertNil(MemoryWritebackCoordinator.extractCanonicalFact(from: "Tell me about the moon"))
 }

 func test_extractCanonicalFact_matchesIWorkAt() {
 let fact = MemoryWritebackCoordinator.extractCanonicalFact(from: "I work at Cactus Compute, building voice agents")
 XCTAssertEqual(fact?.fileName, "user_employer.md")
 XCTAssertTrue(fact?.content.contains("Employer: Cactus Compute") ?? false)
 }

 func test_afterTurn_writesUserNameAndIndexEntry() async throws {
 let index = makeTempSessionIndex
 let session = try await index.create(workspace: nil)
 let store = makeTempMemoryStore

 let coordinator = MemoryWritebackCoordinator(
 sessionIndex: index,
 memoryStore: store
 )

 await coordinator.afterTurn(
 sessionId: session.id,
 userMessage: makeUserMessage("My name is Isaac"),
 assistantMessage: makeAssistantMessage("Got it. I'll remember that."),
 wasVoiceTurn: false
 )

 // Topic file written with name body.
 let body = try await store.readFile("user_name.md")
 XCTAssertTrue(body.contains("Name: Isaac"))

 // Index updated with one bullet pointing at user_name.md.
 let indexBody = await store.loadIndex ?? ""
 XCTAssertTrue(indexBody.contains("user_name.md"))
 XCTAssertTrue(indexBody.contains("User name"))
 }

 func test_afterTurn_overwritesNameOnRedeclare() async throws {
 let index = makeTempSessionIndex
 let session = try await index.create(workspace: nil)
 let store = makeTempMemoryStore
 let coordinator = MemoryWritebackCoordinator(
 sessionIndex: index,
 memoryStore: store
 )

 await coordinator.afterTurn(
 sessionId: session.id,
 userMessage: makeUserMessage("My name is Isaac"),
 assistantMessage: makeAssistantMessage("Got it."),
 wasVoiceTurn: false
 )
 await coordinator.afterTurn(
 sessionId: session.id,
 userMessage: makeUserMessage("My name is Bob"),
 assistantMessage: makeAssistantMessage("Updated."),
 wasVoiceTurn: false
 )

 let body = try await store.readFile("user_name.md")
 XCTAssertTrue(body.contains("Name: Bob"))
 XCTAssertFalse(body.contains("Isaac"))

 // Index is idempotent on duplicate bullets.
 let indexBody = await store.loadIndex ?? ""
 let occurrences = indexBody.components(separatedBy: "user_name.md").count - 1
 XCTAssertEqual(occurrences, 1, "duplicate index bullets must not accumulate")
 }

 // MARK: - Round-6 error log wiring

 func test_afterTurn_doesNotWriteErrorLogOnSuccessPath() async throws {
 // Sanity check that the success path does NOT touch the error
 // log. The error-log mechanism itself is exercised by
 // MemoryStoreTests.test_appendErrorLog_*; here we just verify
 // the coordinator wiring doesn't accidentally fire on success.
 let index = makeTempSessionIndex
 let session = try await index.create(workspace: nil)
 let store = makeTempMemoryStore
 let coordinator = MemoryWritebackCoordinator(
 sessionIndex: index,
 memoryStore: store
 )

 await coordinator.afterTurn(
 sessionId: session.id,
 userMessage: makeUserMessage("My name is Isaac"),
 assistantMessage: makeAssistantMessage("Got it."),
 wasVoiceTurn: false
 )

 // Locate the memory root via a known write — the topic file
 // exists under the root, so its parent is the root.
 let listed = try await store.listFiles
 XCTAssertTrue(listed.contains("user_name.md"), "expected canonical writeback to succeed")
 // No error log entry should have been written.
 let names = try await store.listFiles
 XCTAssertFalse(
 names.contains(MemoryStore.writebackErrorLogName),
 "error log must not be created on the success path"
 )
 }

 func test_afterTurn_skipsWritebackWhenNoMemoryStore() async throws {
 // Headless / smoke-test path: memoryStore == nil. afterTurn must
 // still update the watermark (existing behavior) and NOT crash
 // attempting deterministic writeback.
 let index = makeTempSessionIndex
 let session = try await index.create(workspace: nil)
 let coordinator = MemoryWritebackCoordinator(sessionIndex: index, memoryStore: nil)

 await coordinator.afterTurn(
 sessionId: session.id,
 userMessage: makeUserMessage("My name is Isaac"),
 assistantMessage: makeAssistantMessage("Got it."),
 wasVoiceTurn: false
 )

 guard let post = await index.get(session.id) else {
 return XCTFail("expected session to exist post-call")
 }
 XCTAssertEqual(post.lastIndexedMessageCount, post.messageCount)
 }
}
