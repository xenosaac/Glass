import XCTest
@testable import Relay

final class TurnCommitCoordinatorTests: XCTestCase {
 private func makeTempDir(_ prefix: String) throws -> URL {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 return dir
 }

 private func userText(_ text: String) -> RelayMessage {
 .user(UserContent(blocks: [.text(text)]))
 }

 private func assistantText(_ text: String) -> RelayMessage {
 .assistant(AssistantContent(blocks: [.text(text)]))
 }

 private func messageText(_ message: RelayMessage) -> String {
 switch message {
 case .user(let content):
 return content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }.joined(separator: "\n")
 case .assistant(let content):
 return content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }.joined(separator: "\n")
 case .toolResult(let blocks):
 return blocks.map(\.output).joined(separator: "\n")
 }
 }

 func test_commitCoordinator_completedTurn_commitsInFixedOrder() async throws {
 let sessionsDir = try makeTempDir("commit-sessions")
 let sidecarsDir = try makeTempDir("commit-sidecars")
 let sessionIndex = SessionIndex(baseDir: sessionsDir)
 try await sessionIndex.load
 let metadata = try await sessionIndex.create
 let sessionStore = SessionStore(sessionId: metadata.id, baseDir: sessionsDir)
 let sidecarStore = RuntimeSidecarStore(sessionId: metadata.id, baseDir: sidecarsDir)
 let coordinator = TurnCommitCoordinator(
 sessionId: metadata.id,
 sessionStore: sessionStore,
 sessionIndex: sessionIndex,
 memoryWritebackCoordinator: MemoryWritebackCoordinator(sessionIndex: sessionIndex),
 runtimeSidecarStore: sidecarStore
 )

 var trace = await coordinator.commitAcceptedUserTurn(
 turnID: UUID,
 message: userText("hello"),
 firstUserText: "hello"
 )
 trace = await coordinator.commitCompletedTurn(
 acceptedUserMessage: userText("hello"),
 assistantMessage: assistantText("hi there"),
 wasVoiceTurn: false,
 trace: trace
 )

 let stored = try await sessionStore.loadAll
 XCTAssertEqual(stored.map(messageText), ["hello", "hi there"])
 XCTAssertEqual(
 trace.entries.map(\.stage),
 [
 .acceptedUserTranscriptAppended,
 .acceptedUserIndexed,
 .completedAssistantTranscriptAppended,
 .completedAssistantIndexed,
 .completedMemoryWriteback,
 ]
 )
 let updated = await sessionIndex.get(metadata.id)
 XCTAssertEqual(updated?.messageCount, 2)
 XCTAssertEqual(updated?.lastIndexedMessageCount, 2)
 }

 func test_commitCoordinator_failedTurn_writesSidecarWithoutFakeAssistantMessage() async throws {
 let sessionsDir = try makeTempDir("failure-sessions")
 let sidecarsDir = try makeTempDir("failure-sidecars")
 let sessionIndex = SessionIndex(baseDir: sessionsDir)
 try await sessionIndex.load
 let metadata = try await sessionIndex.create
 let sessionStore = SessionStore(sessionId: metadata.id, baseDir: sessionsDir)
 let sidecarStore = RuntimeSidecarStore(sessionId: metadata.id, baseDir: sidecarsDir)
 let coordinator = TurnCommitCoordinator(
 sessionId: metadata.id,
 sessionStore: sessionStore,
 sessionIndex: sessionIndex,
 memoryWritebackCoordinator: MemoryWritebackCoordinator(sessionIndex: sessionIndex),
 runtimeSidecarStore: sidecarStore
 )

 let turnID = UUID()
 let userMessage = userText("please continue")
 var trace = await coordinator.commitAcceptedUserTurn(
 turnID: turnID,
 message: userMessage,
 firstUserText: "please continue"
 )
 let runArtifacts = TurnRunArtifacts(
 turnID: turnID,
 exit: .modelError,
 recoveryState: RecoveryState(
 lastExit: .modelError,
 lastErrorMessage: "boom",
 cloudFallbackUsedLastTurn: false,
 consecutiveFailures: 1,
 lastCompletedAtTurnCount: nil,
 lastContinuationReason: .fatalError,
 lastWithheldRecoverableError: nil,
 recoveryAttemptCountLastTurn: 0
 ),
 attempts: [],
 acceptedUserMessage: userMessage,
 finalAssistantMessage: nil
 )

 trace = await coordinator.commitFailedTurn(
 runArtifacts: runArtifacts,
 canonicalTranscriptSnapshot: [userMessage],
 trace: trace
 )

 let stored = try await sessionStore.loadAll
 XCTAssertEqual(stored.map(messageText), ["please continue"])
 let sidecar = try await sidecarStore.load(turnID: turnID)
 XCTAssertNotNil(sidecar)
 XCTAssertEqual(sidecar?.failureKind, .modelError)
 XCTAssertEqual(
 trace.entries.map(\.stage),
 [
 .acceptedUserTranscriptAppended,
 .acceptedUserIndexed,
 .failureSidecarWritten,
 ]
 )
 }
}
