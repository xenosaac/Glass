import XCTest
@testable import Relay

final class RuntimeSidecarStoreTests: XCTestCase {
 private func makeTempDir(_ prefix: String) throws -> URL {
 let dir = FileManager.default.temporaryDirectory
 .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
 try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 return dir
 }

 func test_exporter_sanitizesPathsAndProducesDeterministicFixture() throws {
 let diagnostics = PromptCompositionDiagnostics(sections: [], rendered: "")
 let attempt = TurnAttemptDiagnostics(
 attemptIndex: 1,
 modelTier: .fast,
 requestMessages: [
 .user(UserContent(blocks: [.text("read /Users/demo/Desktop/private.txt")]))
 ],
 systemPrompt: "Workspace: /Users/demo/Workspace/Glass",
 promptDiagnostics: diagnostics,
 currentTurnFocus: "# Current turn focus\nLatest user message:\nsee /Users/demo/Desktop/private.txt",
 retrievalDecision: RetrievalDecisionSummary(
 selectedArtifacts: [
 RetrievedArtifactRef(
 kind: .workspace,
 sourceDisplayName: "Notes.md",
 artifactID: "/Users/demo/Desktop/private.txt",
 position: nil,
 totalParts: nil,
 tokenEstimate: 24,
 score: 1.0
 )
 ],
 injectedArtifactCount: 1
 ),
 wasTruncated: false,
 emittedRecoveryEvents: [.clearProvisionalOutput],
 completionSnapshot: nil,
 errorSummary: "fatal read at /Users/demo/Desktop/private.txt"
 )
 let sidecar = TurnRuntimeSidecar(
 sessionId: "session-1234",
 turnID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
 failureKind: .modelError,
 canonicalTranscriptSnapshot: [
 .user(UserContent(blocks: [.text("session-1234 /Users/demo/Desktop/private.txt")]))
 ],
 acceptedUserMessage: .user(UserContent(blocks: [.text("please check /Users/demo/Desktop/private.txt")])),
 attempts: [attempt],
 commitTrace: TurnCommitTrace,
 recoveryState: RecoveryState(
 lastExit: .modelError,
 lastErrorMessage: "fatal read at /Users/demo/Desktop/private.txt",
 cloudFallbackUsedLastTurn: false,
 consecutiveFailures: 1,
 lastCompletedAtTurnCount: nil,
 lastContinuationReason: .fatalError,
 lastWithheldRecoverableError: nil,
 recoveryAttemptCountLastTurn: 0
 ),
 terminalErrorMessage: "fatal read at /Users/demo/Desktop/private.txt"
 )

 let exporter = ReplayFixtureExporter()
 let first = exporter.export(sidecar)
 let second = exporter.export(sidecar)

 let encoder = JSONEncoder()
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 let firstData = try encoder.encode(first)
 let secondData = try encoder.encode(second)
 XCTAssertEqual(firstData, secondData)

 let json = String(decoding: firstData, as: UTF8.self)
 XCTAssertFalse(json.contains("session-1234"))
 XCTAssertFalse(json.contains("/Users/demo/Desktop/private.txt"))
 XCTAssertTrue(json.contains("<session-id>") || json.contains("<path>"))
 }

 func test_sidecarStore_roundTripsFailureSidecar() async throws {
 let dir = try makeTempDir("runtime-sidecars")
 let store = RuntimeSidecarStore(sessionId: "roundtrip", baseDir: dir)
 let turnID = UUID()
 let sidecar = TurnRuntimeSidecar(
 sessionId: "roundtrip",
 turnID: turnID,
 failureKind: .interrupted,
 canonicalTranscriptSnapshot: [.user(UserContent(blocks: [.text("hello")]))],
 acceptedUserMessage: .user(UserContent(blocks: [.text("hello")])) ,
 attempts: [],
 commitTrace: TurnCommitTrace(entries: [
 TurnCommitStageEntry(stage: .acceptedUserTranscriptAppended, succeeded: true)
 ]),
 recoveryState: RecoveryState(
 lastExit: .interrupted,
 lastErrorMessage: nil,
 cloudFallbackUsedLastTurn: false,
 consecutiveFailures: 0,
 lastCompletedAtTurnCount: nil,
 lastContinuationReason: .interruptCleanup,
 lastWithheldRecoverableError: nil,
 recoveryAttemptCountLastTurn: 0
 ),
 terminalErrorMessage: nil
 )

 _ = try await store.save(sidecar)
 let loaded = try await store.load(turnID: turnID)

 XCTAssertNotNil(loaded)
 XCTAssertEqual(loaded?.failureKind, .interrupted)
 XCTAssertEqual(loaded?.commitTrace.entries.count, 1)
 }

 func test_sidecarStore_migratesLegacyBarePayloadToEnvelope() async throws {
 let dir = try makeTempDir("runtime-sidecars-legacy")
 let store = RuntimeSidecarStore(sessionId: "legacy", baseDir: dir)
 let turnID = UUID()
 let sidecar = TurnRuntimeSidecar(
 sessionId: "legacy",
 turnID: turnID,
 failureKind: .modelError,
 canonicalTranscriptSnapshot: [.user(UserContent(blocks: [.text("hi")]))],
 acceptedUserMessage: .user(UserContent(blocks: [.text("hi")])),
 attempts: [],
 commitTrace: TurnCommitTrace,
 recoveryState: RecoveryState(
 lastExit: .modelError,
 lastErrorMessage: "bad",
 cloudFallbackUsedLastTurn: false,
 consecutiveFailures: 1,
 lastCompletedAtTurnCount: nil,
 lastContinuationReason: .fatalError,
 lastWithheldRecoverableError: nil,
 recoveryAttemptCountLastTurn: 0
 ),
 terminalErrorMessage: "bad"
 )

 let encoder = JSONEncoder()
 encoder.dateEncodingStrategy = .iso8601
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 let legacyURL = dir.appendingPathComponent("\(turnID.uuidString).json")
 try encoder.encode(sidecar).write(to: legacyURL, options: .atomic)

 let loaded = try await store.load(turnID: turnID)
 XCTAssertEqual(loaded?.failureKind, .modelError)

 let decoder = JSONDecoder()
 decoder.dateDecodingStrategy = .iso8601
 let persisted = try Data(contentsOf: legacyURL)
 let envelope = try decoder.decode(VersionedStoreEnvelope<TurnRuntimeSidecar>.self, from: persisted)
 XCTAssertEqual(envelope.header.storeID, .runtimeSidecar)
 XCTAssertEqual(envelope.payload.turnID, turnID)
 }

 func test_replayFixtureStore_roundTripsDerivedEnvelope() async throws {
 let dir = try makeTempDir("replay-fixtures")
 let store = ReplayFixtureStore(baseDir: dir)
 let fixture = ReplayFixture(
 name: "sample",
 canonicalHistory: [.user(UserContent(blocks: [.text("hello")]))],
 acceptedUserMessage: .user(UserContent(blocks: [.text("hello")])),
 onDeviceSteps: [ReplayModelStep(isEmpty: true)],
 expectation: ReplayExpectation(exit: .interrupted)
 )

 let url = try await store.save(fixture, name: "sample")
 let loaded = try await store.load(name: "sample")
 XCTAssertEqual(loaded?.name, "sample")

 let persisted = try Data(contentsOf: url)
 let envelope = try JSONDecoder.decode(VersionedStoreEnvelope<ReplayFixture>.self, from: persisted)
 XCTAssertEqual(envelope.header.storeID, .replayFixtureExport)
 XCTAssertEqual(envelope.payload.name, "sample")
 }
}
