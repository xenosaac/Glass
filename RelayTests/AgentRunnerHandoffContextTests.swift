import XCTest
@testable import Relay

/// Intervention 5 regression guard.
///
/// The two-model handoff (on-device Gemma → cloud Gemini) works by
/// calling `CompiledTurnRequest.with(profileID: .geminiCloud, ...)` to
/// clone the on-device request for the cloud path (see AgentRunner
/// line 639-647). The contract these tests lock: the clone preserves
/// (a) the compiled system prompt (which, after R7-A Intervention 2,
/// carries per-tool descriptions that guide cloud tool selection),
/// (b) the full tool history (prior `tool_use` + `tool_result` blocks),
/// (c) the tool catalog.
/// If any of these drifts in a future refactor, the cloud handoff will
/// land without context and we'll see identity-violation fallbacks
/// just like the pre-R7 device logs showed.
final class AgentRunnerHandoffContextTests: XCTestCase {

 private let environment = SystemPrompt.Environment(
 model: "gemma-4-e2b-it",
 platform: "iOS 26.0",
 currentDate: "2026-04-16"
 )

 func test_handoff_preservesPromptMessagesAndCatalog() {
 // Build a PromptAssembly with per-tool descriptions (Intervention 2).
 let promptInput = PromptCompiler.Input(
 profileID: .gemmaLocal,
 enabledToolNames: ["calendar_list_events"],
 toolDescriptions: ["calendar_list_events": "List upcoming calendar events within a date range."],
 environment: environment,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: [:]
 )
 let assembly = PromptCompiler.compile(promptInput)
 XCTAssertTrue(
 assembly.rendered.contains("calendar_list_events: List upcoming"),
 "sanity: Intervention 2 descriptions must be in the rendered prompt"
 )

 // Messages include a tool_use / tool_result pair simulating what
 // the on-device model produced before triggering cloud handoff.
 let toolUse = ToolUseBlock(id: "u1", name: "calendar_list_events", inputJson: "{}")
 let toolResult = ToolResultBlock(toolUseId: "u1", output: "Found 3 events", isError: false)
 let messages: [RelayMessage] = [
 .user(UserContent(blocks: [.text("What's on my calendar?")])),
 .assistant(AssistantContent(blocks: [.toolUse(toolUse)])),
 .toolResult([toolResult])
 ]

 let catalog: [ToolCatalogEntry] = [
 ToolCatalogEntry(
 name: "calendar_list_events",
 title: "List upcoming calendar events within a date range.",
 source: .other,
 inputSchema: #"{"type":"object","properties":{}}"#,
 policy: .readOnly(
 domain: .calendar,
 operation: .read,
 summary: "List upcoming calendar events."
 )
 )
 ]

 let onDeviceRequest = CompiledTurnRequest(
 turnID: UUID,
 sessionID: "sess-handoff-test",
 profileID: .gemmaLocal,
 messages: messages,
 promptAssembly: assembly,
 toolCatalog: catalog,
 hostOptions: HostExecutionOptions(
 completionOptions: .init(),
 toolMode: .allowed,
 emitVisibleTokens: true,
 allowCloudHandoff: true
 ),
 wasTruncated: false,
 retrievalPlan: nil,
 bindingContext: nil,
 recoveryPlan: nil,
 diagnostics: CompiledTurnDiagnostics(
 promptAssembly: assembly,
 turnOverlay: nil,
 currentTurnFocus: nil,
 latestNonMetaUserText: "What's on my calendar?",
 turnClassification: .question,
 retrievalQuery: nil,
 retrievalDecision: nil
 )
 )

 // The actual handoff transform — mirrors AgentRunner.swift:639-647.
 let cloudRequest = onDeviceRequest.with(profileID: .geminiCloud)

 // (a) Prompt with descriptions must survive.
 XCTAssertEqual(cloudRequest.promptAssembly.rendered, onDeviceRequest.promptAssembly.rendered)
 XCTAssertTrue(cloudRequest.promptAssembly.rendered.contains("calendar_list_events: List upcoming"))

 // (b) Tool history must survive intact.
 XCTAssertEqual(cloudRequest.messages.count, 3)
 var sawToolUse = false
 var sawToolResult = false
 for msg in cloudRequest.messages {
 if case .assistant(let c) = msg {
 for block in c.blocks {
 if case .toolUse(let u) = block, u.id == "u1" { sawToolUse = true }
 }
 }
 if case .toolResult(let blocks) = msg, blocks.contains(where: { $0.toolUseId == "u1" }) {
 sawToolResult = true
 }
 }
 XCTAssertTrue(sawToolUse, "tool_use block lost across handoff")
 XCTAssertTrue(sawToolResult, "tool_result block lost across handoff")

 // (c) Tool catalog must survive.
 XCTAssertEqual(cloudRequest.toolCatalog.map { $0.name }, ["calendar_list_events"])
 XCTAssertEqual(cloudRequest.toolCatalog.first?.title, "List upcoming calendar events within a date range.")

 // Profile must flip.
 XCTAssertEqual(cloudRequest.profileID, .geminiCloud)
 XCTAssertEqual(onDeviceRequest.profileID, .gemmaLocal)
 }
}
