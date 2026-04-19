import XCTest
@testable import Relay

final class HostContractsTests: XCTestCase {

 private struct Envelope: Codable, Equatable {
 let request: CompiledTurnRequest
 let response: CompiledTurnResponse
 let executionPlan: TurnExecutionPlan
 }

 private func makePromptAssembly() -> PromptAssembly {
 PromptCompiler.compile(
 .init(
 profileID: .gemmaLocal,
 enabledToolNames: ["echo"],
 environment: .current,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: ["workspace": "/tmp/demo"],
 currentTurnFocus: """
 # Current turn focus
 - Treat the latest user message as the primary query.
 """
 )
 )
 }

 func test_compiledTurnContracts_roundTripCodably() throws {
 let promptAssembly = makePromptAssembly
 let turnOverlay = TurnOverlayBundle(
 classification: .factRecallKnown,
 bindingPriority: .latestTurnWithVisibleFacts,
 latestUserText: "What's my name?",
 visibleFacts: [
 VisibleFactRecord(
 text: "My name is Isaac",
 sourceTurnIndex: 0,
 sourceClassification: .declarativeFact
 )
 ],
 recentTail: [
 BoundConversationTurn(role: "assistant", text: "I remember your name.")
 ],
 retrievalArtifacts: [],
 summarySnippet: "Older summary",
 instructions: ["Answer using the visible fact."]
 )
 let retrievalPlan = RetrievalDecisionSummary(
 selectedArtifacts: [
 RetrievedArtifactRef(
 kind: .attachment,
 sourceDisplayName: "notes.txt",
 artifactID: "artifact-1",
 position: 0,
 totalParts: 1,
 tokenEstimate: 80,
 score: 0.9
 )
 ],
 injectedArtifactCount: 1
 )
 let request = CompiledTurnRequest(
 turnID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
 sessionID: "session-123",
 profileID: .gemmaLocal,
 messages: [.user(UserContent(blocks: [.text("What's my name?")]))],
 promptAssembly: promptAssembly,
 toolCatalog: [
 ToolCatalogEntry(
 name: "echo",
 title: "Echo",
 source: .builtin,
 inputSchema: #"{"type":"object"}"#,
 policy: ToolPolicyDescriptor(
 domain: .filesystem,
 operation: .read,
 risk: .readOnly,
 summary: "Read-only"
 )
 )
 ],
 hostOptions: HostExecutionOptions(
 completionOptions: .init(),
 toolMode: .allowed,
 emitVisibleTokens: true,
 allowCloudHandoff: true
 ),
 wasTruncated: false,
 retrievalPlan: retrievalPlan,
 bindingContext: turnOverlay,
 recoveryPlan: RecoveryState(
 lastExit: .completed,
 lastErrorMessage: nil,
 cloudFallbackUsedLastTurn: false,
 consecutiveFailures: 0,
 lastCompletedAtTurnCount: 1,
 lastContinuationReason: .completed,
 lastWithheldRecoverableError: nil,
 recoveryAttemptCountLastTurn: 0
 ),
 diagnostics: CompiledTurnDiagnostics(
 promptAssembly: promptAssembly,
 turnOverlay: turnOverlay,
 currentTurnFocus: "# Current turn focus\n- Use the remembered name.",
 latestNonMetaUserText: "What is my name?",
 turnClassification: .factRecallKnown,
 retrievalQuery: "what's my name",
 retrievalDecision: retrievalPlan
 )
 )
 let response = CompiledTurnResponse(
 tier: .fast,
 outputText: "Your name is Isaac.",
 toolCalls: [],
 finishReason: .message,
 rawCompletion: CompletionSnapshot(
 text: "Your name is Isaac.",
 toolCalls: [],
 confidence: 0.99,
 cloudHandoff: false,
 prefillTPS: 10,
 decodeTPS: 20,
 timeToFirstTokenMs: 100,
 totalTimeMs: 200,
 ramUsageMB: 300
 )
 )
 let envelope = Envelope(
 request: request,
 response: response,
 executionPlan: TurnExecutionPlan(
 maxLoops: 10,
 allowCloudFallback: true,
 allowToolSpecialist: true,
 profileID: .gemmaLocal,
 hostOptions: request.hostOptions
 )
 )

 let data = try JSONEncoder.encode(envelope)
 let decoded = try JSONDecoder.decode(Envelope.self, from: data)

 XCTAssertEqual(decoded, envelope)
 }

 func test_recoveryAndRetrievalSummaries_roundTripCodably() throws {
 let recovery = RecoveryState(
 lastExit: .modelError,
 lastErrorMessage: "prompt too long",
 cloudFallbackUsedLastTurn: true,
 consecutiveFailures: 2,
 lastCompletedAtTurnCount: 4,
 lastContinuationReason: .cloudRetry,
 lastWithheldRecoverableError: "trimmed retry",
 recoveryAttemptCountLastTurn: 1
 )
 let retrieval = RetrievalDecisionSummary(
 selectedArtifacts: [
 RetrievedArtifactRef(
 kind: .workspace,
 sourceDisplayName: "doc.md",
 artifactID: "doc-1",
 position: 2,
 totalParts: 5,
 tokenEstimate: 120,
 score: 0.75
 )
 ],
 injectedArtifactCount: 1
 )

 let recoveryData = try JSONEncoder.encode(recovery)
 let retrievalData = try JSONEncoder.encode(retrieval)

 XCTAssertEqual(try JSONDecoder.decode(RecoveryState().self, from: recoveryData), recovery)
 XCTAssertEqual(try JSONDecoder.decode(RetrievalDecisionSummary().self, from: retrievalData), retrieval)
 }
}
