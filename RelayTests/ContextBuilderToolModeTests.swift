import XCTest
@testable import Relay

final class ContextBuilderToolModeTests: XCTestCase {

 private static let probeEnvironment = SystemPrompt.Environment(
 model: "probe",
 platform: "probe",
 currentDate: "2026-04-16"
 )

 private static let probeCatalog: [ToolCatalogEntry] = [
 ToolCatalogEntry(
 name: "probe",
 title: "Probe",
 source: .other,
 inputSchema: "{}",
 policy: ToolPolicyDescriptor(
 domain: .other,
 operation: .read,
 risk: .readOnly,
 summary: "Probe"
 )
 )
 ]

 private func makeBuilder() -> ContextBuilder {
 ContextBuilder(memoryStore: nil)
 }

 private func makeState(latestUserText: String) -> AgentSessionState {
 AgentSessionState(
 messages: [.user(UserContent(blocks: [.text(latestUserText)]))],
 turnCount: 1
 )
 }

 func test_toolMode_isRequired_forToolIntentUserText() async {
 let builder = makeBuilder
 let request = await builder.buildCompiledTurn(
 turnID: UUID,
 sessionID: "probe",
 state: makeState(latestUserText: "Find the latest working entry about module B"),
 enabledToolNames: ["probe"],
 environment: Self.probeEnvironment,
 extraSystemContext: [:],
 toolCatalog: Self.probeCatalog,
 options: CactusModelHost.CompletionOptions
 )
 XCTAssertEqual(request.hostOptions.toolMode, .required)
 }

 func test_toolMode_isAllowed_forNeutralUserText() async {
 let builder = makeBuilder
 let request = await builder.buildCompiledTurn(
 turnID: UUID,
 sessionID: "probe",
 state: makeState(latestUserText: "Hi, how are you?"),
 enabledToolNames: ["probe"],
 environment: Self.probeEnvironment,
 extraSystemContext: [:],
 toolCatalog: Self.probeCatalog,
 options: CactusModelHost.CompletionOptions
 )
 XCTAssertEqual(request.hostOptions.toolMode, .allowed)
 }
}
