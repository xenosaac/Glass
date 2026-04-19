import XCTest
@testable import Relay

final class PromptCompilerTests: XCTestCase {

 private struct EmptyTool: RelayTool {
 var name: String { "empty" }
 var description: String { "test tool" }
 var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 var isConcurrencySafe: Bool { true }
 var isReadOnly: Bool { true }
 var isDestructive: Bool { false }

 func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 ToolResult(toolUseId: "", output: "ok", isError: false)
 }
 }

 private let environment = SystemPrompt.Environment(
 model: "gemma-4-e2b-it",
 platform: "iOS 26.0",
 currentDate: "2026-04-14"
 )

 func test_promptCompiler_matchesLegacyAssembly_withoutOptionalSections() {
 let input = makeInput
 assertParity(for: input)
 }

 func test_promptCompiler_matchesLegacyAssembly_withToolsOnly() {
 let input = makeInput(enabledToolNames: ["web_search", "memory_write"])
 assertParity(for: input)
 }

 func test_promptCompiler_matchesLegacyAssembly_withMemoryOnly() {
 let input = makeInput(
 memoryIndex: "- [Isaac](user_isaac.md) — name and preferences",
 memoryTopics: ["user_isaac.md": "Isaac likes concise replies."]
 )
 assertParity(for: input)
 }

 // MARK: - Round-6 topic bodies inlined under memory section

 func test_promptCompiler_inlinesTopicBodiesUnderMemorySection() {
 // The smoking-gun fix: topic bodies are now rendered under
 // `## Topic file contents` so the model can answer fact-recall
 // questions directly from the system prompt without round-tripping
 // any tool. Pre-Round-6 this assertion would fail (rendered output
 // contained only the index bullet, never the body text).
 let input = makeInput(
 memoryIndex: "- [User name](user_name.md) — current user's preferred name",
 memoryTopics: ["User name": "Name: Isaac"]
 )
 let compilation = PromptCompiler.compile(input)
 XCTAssertTrue(
 compilation.rendered.contains("## Topic file contents"),
 "expected topics block to render; rendered = \(compilation.rendered)"
 )
 XCTAssertTrue(
 compilation.rendered.contains("### User name"),
 "expected topic header to render"
 )
 XCTAssertTrue(
 compilation.rendered.contains("Name: Isaac"),
 "expected topic body to render"
 )
 }

 func test_promptCompiler_omitsTopicSectionWhenTopicsEmpty() {
 let input = makeInput(
 memoryIndex: "- [User name](user_name.md) — current user's preferred name",
 memoryTopics: [:]
 )
 let compilation = PromptCompiler.compile(input)
 XCTAssertFalse(
 compilation.rendered.contains("## Topic file contents"),
 "expected topics block to be omitted when topics empty"
 )
 }

 func test_promptCompiler_topicsBlockSortsAlphabeticallyForCacheStability() {
 // Order matters: the prompt cache key is content-derived. If we
 // render topics in dict order (non-deterministic), every turn
 // would invalidate the cache. Sort by displayName key.
 let input = makeInput(
 memoryIndex: "- index unchanged",
 memoryTopics: [
 "Zebra fact": "Z body",
 "Apple fact": "A body",
 "Mango fact": "M body"
 ]
 )
 let compilation = PromptCompiler.compile(input)
 guard let appleRange = compilation.rendered.range(of: "### Apple fact"),
 let mangoRange = compilation.rendered.range(of: "### Mango fact"),
 let zebraRange = compilation.rendered.range(of: "### Zebra fact") else {
 return XCTFail("expected all three topic headers in rendered output")
 }
 XCTAssertLessThan(appleRange.lowerBound, mangoRange.lowerBound)
 XCTAssertLessThan(mangoRange.lowerBound, zebraRange.lowerBound)
 }

 // MARK: - memory trim + tool governance

 func test_memorySection_isTrimmedWhenIndexNonEmpty() {
 // 1 full-block branch reduced from ~470 to
 // ~150 tokens. Sanity check: rendered section contains the
 // tightened explicit-trigger sentence and the index, but NOT
 // the dropped "What NOT to save" / 4-type taxonomy bullets.
 let input = makeInput(
 memoryIndex: "- [User name](user_name.md) — current user's preferred name",
 memoryTopics: ["User name": "Name: Isaac"]
 )
 let rendered = PromptCompiler.compile(input).rendered
 XCTAssertTrue(rendered.contains("Persistent on-device memory"))
 XCTAssertTrue(rendered.contains("explicitly asks you to remember"))
 XCTAssertTrue(rendered.contains("## Current MEMORY.md"))
 XCTAssertTrue(rendered.contains("## Topic file contents"))
 // Dropped sections — must NOT appear.
 XCTAssertFalse(rendered.contains("What NOT to save"))
 XCTAssertFalse(rendered.contains("Types of memory"))
 XCTAssertFalse(rendered.contains("How to save (two steps)"))
 XCTAssertFalse(rendered.contains("Build up this memory over time"),
 "verbose build-up directive should be dropped")
 }

 func test_basePromptSections_includesToolGovernanceWhenToolsEnabled() {
 // 1 tool selection guidance section
 // appears after available tools, before the dynamic boundary.
 let input = makeInput(enabledToolNames: ["get_current_datetime", "memory_write", "calendar_list_events", "reminders_list"])
 let compilation = PromptCompiler.compile(input)
 XCTAssertTrue(compilation.rendered.contains("# Tool selection"))
 XCTAssertTrue(compilation.rendered.contains("get_current_datetime"))
 XCTAssertTrue(compilation.rendered.contains("calendar_list_events"))
 XCTAssertTrue(compilation.rendered.contains("reminders_list"))
 XCTAssertTrue(compilation.rendered.contains("explicit save requests ONLY"))
 // Section ordering: Tool selection must appear AFTER the
 // "# Available tools" header but BEFORE the dynamic boundary
 // marker, so it stays in the cacheable stable prefix.
 guard let toolsRange = compilation.rendered.range(of: "# Available tools"),
 let governanceRange = compilation.rendered.range(of: "# Tool selection"),
 let boundaryRange = compilation.rendered.range(of: SystemPrompt.dynamicBoundary) else {
 return XCTFail("expected all three section markers in rendered prompt")
 }
 XCTAssertLessThan(toolsRange.lowerBound, governanceRange.lowerBound)
 XCTAssertLessThan(governanceRange.lowerBound, boundaryRange.lowerBound)
 }

 func test_toolGovernanceSection_omitsRulesForUnconfiguredTools() {
 // Only `get_current_datetime` is enabled — should NOT mention
 // the calendar / reminders / memory_write rules.
 let input = makeInput(enabledToolNames: ["get_current_datetime"])
 let rendered = PromptCompiler.compile(input).rendered
 XCTAssertTrue(rendered.contains("# Tool selection"))
 XCTAssertTrue(rendered.contains("get_current_datetime"))
 XCTAssertFalse(rendered.contains("calendar_list_events"),
 "should not mention unconfigured calendar tool")
 XCTAssertFalse(rendered.contains("reminders_list"),
 "should not mention unconfigured reminders tool")
 XCTAssertFalse(rendered.contains("explicit save requests"),
 "should not mention memory_write rule when tool absent")
 }

 func test_promptCompiler_topicsBlockRendersEvenWithEmptyIndex() {
 // Edge case: cold-start stub keeps the index non-empty in
 // production (Layer 2). But if a test forces an empty index AND
 // provides topics, the topics block should still render — the
 // model needs to see facts even if the index is somehow blank.
 let input = makeInput(
 memoryIndex: nil,
 memoryTopics: ["User name": "Name: Isaac"]
 )
 let compilation = PromptCompiler.compile(input)
 XCTAssertTrue(
 compilation.rendered.contains("## Topic file contents"),
 "expected topics block to render even when memoryIndex is nil"
 )
 XCTAssertTrue(compilation.rendered.contains("Name: Isaac"))
 }

 func test_promptCompiler_matchesLegacyAssembly_withExtraSystemContextOnly() {
 let input = makeInput(extraSystemContext: [
 "workspace": "/tmp/demo",
 "mode": "voice"
 ])
 assertParity(for: input)
 }

 func test_promptCompiler_matchesLegacyAssembly_withCurrentTurnFocusOnly() {
 let input = makeInput(
 currentTurnFocus: """
 # Current turn focus
 - Treat the latest user message as the primary query.
 """
 )
 assertParity(for: input)
 }

 func test_promptCompiler_matchesLegacyAssembly_withAllModule01Inputs() {
 let input = makeInput(
 enabledToolNames: ["memory_write", "web_search"],
 memoryIndex: "- [Isaac](user_isaac.md) — name and preferences",
 memoryTopics: ["user_isaac.md": "Isaac likes concise replies."],
 extraSystemContext: ["workspace": "/tmp/demo", "mode": "voice"],
 currentTurnFocus: """
 # Current turn focus
 - Treat the latest user message as the primary query.
 - Latest user message:
 What's my name?
 """
 )
 assertParity(for: input)
 }

 func test_promptCompiler_diagnostics_tracksOrderAndLayers() {
 let input = makeInput(
 enabledToolNames: ["memory_write", "web_search"],
 memoryIndex: "- [Isaac](user_isaac.md) — name and preferences",
 memoryTopics: ["user_isaac.md": "Isaac likes concise replies."],
 extraSystemContext: ["workspace": "/tmp/demo", "mode": "voice"],
 currentTurnFocus: """
 # Current turn focus
 - Treat the latest user message as the primary query.
 """
 )

 let compilation = PromptCompiler.compile(input)
 // Prompt surgery removed interactionStyle / toneAndStyle /
 // outputEfficiency from the stable-bootstrap list; their behaviors now
 // live in exampleBank few-shot examples instead.
 let expectedOrder: [PromptSectionID] = [
 .intro,
 .systemRules,
 .answering,
 .multimodal,
 .availableTools,
 .dynamicBoundary,
 .memory,
 .environment,
 .extraSystemContext,
 .currentTurnFocus,
 ]

 XCTAssertEqual(compilation.diagnostics.sectionOrder, expectedOrder)
 XCTAssertEqual(
 compilation.diagnostics.sectionsByLayer[.stableBootstrap],
 [.intro, .systemRules, .answering, .multimodal, .availableTools, .dynamicBoundary, .memory, .environment, .extraSystemContext]
 )
 XCTAssertEqual(compilation.diagnostics.sectionsByLayer[.dynamicTurn], [.currentTurnFocus])
 XCTAssertEqual(compilation.diagnostics.sectionsByLayer[.recoveryRuntime], [])
 XCTAssertEqual(compilation.sections.first(where: { $0.id == .dynamicBoundary })?.layer, .stableBootstrap)
 XCTAssertEqual(compilation.diagnostics.totalCharacters, compilation.rendered.count)
 XCTAssertEqual(
 compilation.diagnostics.totalEstimatedTokens,
 compilation.diagnostics.estimatedTokensByLayer.values.reduce(0, +)
 )
 }

 func test_promptCompiler_diagnostics_representsEmptyRecoveryLayer() {
 let compilation = PromptCompiler.compile(makeInput)

 XCTAssertEqual(compilation.diagnostics.sectionsByLayer[.recoveryRuntime], [])
 XCTAssertFalse(compilation.diagnostics.sectionOrder.contains(.recoveryNotes))
 XCTAssertEqual(compilation.diagnostics.characterCountByLayer[.recoveryRuntime], 0)
 XCTAssertEqual(compilation.diagnostics.estimatedTokensByLayer[.recoveryRuntime], 0)
 }

 func test_promptCompiler_moduleA_contractMetadata_defaultsStayDormant() {
 let compilation = PromptCompiler.compile(makeInput(
 enabledToolNames: ["memory_write", "web_search"],
 currentTurnFocus: """
 # Current turn focus
 - Treat the latest user message as the primary query.
 """
 ))

 XCTAssertEqual(compilation.profileID, .gemmaLocal)
 XCTAssertEqual(compilation.sections.first(where: { $0.id == .intro })?.owner, .systemPrompt)
 XCTAssertEqual(compilation.sections.first(where: { $0.id == .currentTurnFocus })?.owner, .contextBuilder)
 XCTAssertEqual(compilation.sections.first(where: { $0.id == .dynamicBoundary })?.required, true)
 XCTAssertEqual(compilation.sections.first(where: { $0.id == .currentTurnFocus })?.profileApplicability, [.gemmaLocal, .geminiCloud, .functionGemmaTool])
 // Prompt surgery removed 3 stable-bootstrap sections before the
 // availableTools/dynamicBoundary pair, so the boundary moved from 8 to 5.
 XCTAssertEqual(compilation.stableDynamicBoundaryIndex, 5)
 XCTAssertEqual(compilation.selectedExampleModules, [])
 XCTAssertEqual(compilation.budgetPolicy.droppableLayers, [.exampleBank, .providerOverlay])
 XCTAssertTrue(compilation.budgetPolicy.protectedSectionIDs.contains(.availableTools))
 XCTAssertTrue(compilation.budgetPolicy.protectedSectionIDs.contains(.currentTurnFocus))
 XCTAssertTrue(compilation.budgetPolicy.protectedSectionIDs.contains(.recoveryNotes))
 XCTAssertFalse(compilation.sections.contains(where: { $0.layer == .providerOverlay }))
 XCTAssertFalse(compilation.sections.contains(where: { $0.layer == .exampleBank }))
 }

 /// Prompt surgery renamed from `test_promptCompiler_includesNaturalConversationSection`.
 /// Asserts the new shrunk answering section content and that deleted
 /// sections do not reappear. Behavioral shaping previously carried by
 /// `# Interaction style` / `# Tone and style` / `# Output efficiency`
 /// bullets now lives in exampleBank few-shot modules (covered by
 /// `test_promptCompiler_selectsExampleBankForGemmaLocalClassifiedTurns`).
 func test_promptCompiler_rendersShrunkAnsweringSection() {
 let compilation = PromptCompiler.compile(makeInput)

 // New 3-bullet answering section.
 XCTAssertTrue(compilation.rendered.contains("Answer the user's current message directly"))
 XCTAssertTrue(compilation.rendered.contains("I don't have information about"))
 XCTAssertTrue(compilation.rendered.contains("Match the user's language"))

 // Deleted sections must not reappear.
 XCTAssertFalse(compilation.rendered.contains("# Interaction style"))
 XCTAssertFalse(compilation.rendered.contains("# Tone and style"))
 XCTAssertFalse(compilation.rendered.contains("# Output efficiency"))
 XCTAssertFalse(compilation.rendered.contains("Please provide the text or image you would like me to work with"))
 // No turnOverlay in default makeInput → no exampleBank.
 XCTAssertFalse(compilation.rendered.contains("# Current-turn examples"))
 }

 // MARK: - Prompt token budget (surgery )

 /// Cold-start turn with empty memory + standard tool catalog must render
 /// ≤ 600 tokens (UTF-8 bytes / 4 approximation). Pre-surgery baseline was
 /// ~1900 tokens for the same scenario — Gemma-4-E2B on CPU cannot
 /// reliably follow instructions when the prompt exceeds this budget.
 func test_promptCompiler_tokenBudget_coldStartTurn_under600() {
 let input = makeInput(
 enabledToolNames: ["memory_write", "web_search"],
 turnOverlay: makeOverlay(
 classification: .socialOpener,
 latestUserText: "Hi"
 )
 )
 let compilation = PromptCompiler.compile(input)
 let estimatedTokens = compilation.rendered.utf8.count / 4
 XCTAssertLessThanOrEqual(
 estimatedTokens,
 600,
 "Cold-start prompt exceeds token budget — was \(estimatedTokens) tokens. Surgery goal: ≤600."
 )
 }

 /// Populated-memory turn (realistic mid-session state) must stay
 /// ≤ 1000 tokens. Pre-surgery baseline was ~2100 for the same shape.
 func test_promptCompiler_tokenBudget_populatedMemoryTurn_under1000() {
 let input = makeInput(
 enabledToolNames: ["memory_write", "web_search", "file_search", "Read"],
 memoryIndex: "- [Isaac](user_isaac.md) — name, preferences\n- [Project](project_glass.md) — Glass project",
 memoryTopics: ["user_isaac.md": "Isaac likes concise replies."],
 turnOverlay: makeOverlay(
 classification: .declarativeFact,
 latestUserText: "My name is Isaac"
 )
 )
 let compilation = PromptCompiler.compile(input)
 let estimatedTokens = compilation.rendered.utf8.count / 4
 XCTAssertLessThanOrEqual(
 estimatedTokens,
 1000,
 "Populated-memory prompt exceeds token budget — was \(estimatedTokens) tokens. Surgery goal: ≤1000."
 )
 }

 func test_promptCompiler_selectsExampleBankForGemmaLocalClassifiedTurns() {
 let socialCompilation = PromptCompiler.compile(makeInput(
 currentTurnFocus: """
 # Current turn focus
 - Turn classification: socialOpener
 - Latest user message:
 How are you?
 """,
 turnOverlay: makeOverlay(
 classification: .socialOpener,
 latestUserText: "How are you?"
 )
 ))

 XCTAssertEqual(socialCompilation.selectedExampleModules, [PromptExampleModuleID.socialCheckIn])
 XCTAssertEqual(socialCompilation.sections.last?.id, .exampleBank)
 XCTAssertTrue(socialCompilation.rendered.contains("# Current-turn examples"))
 XCTAssertTrue(socialCompilation.rendered.contains("Example: social check-in"))

 let unknownCompilation = PromptCompiler.compile(makeInput(
 turnOverlay: makeOverlay(
 classification: .factRecallUnknown,
 latestUserText: "What is my name?"
 )
 ))
 XCTAssertEqual(unknownCompilation.selectedExampleModules, [PromptExampleModuleID.factRecallUnknown])
 XCTAssertTrue(unknownCompilation.rendered.contains("Example: fact recall with no known answer"))

 let knownCompilation = PromptCompiler.compile(makeInput(
 turnOverlay: makeOverlay(
 classification: .factRecallKnown,
 latestUserText: "What is my name?",
 visibleFacts: [
 VisibleFactRecord(
 text: "My name is Isaac.",
 sourceTurnIndex: 0,
 sourceClassification: .declarativeFact
 )
 ]
 )
 ))
 XCTAssertEqual(knownCompilation.selectedExampleModules, [PromptExampleModuleID.factRecallKnown])
 XCTAssertTrue(knownCompilation.rendered.contains("Example: fact recall with known answer"))

 let referentialCompilation = PromptCompiler.compile(makeInput(
 turnOverlay: makeOverlay(
 classification: .referentialFollowup,
 latestUserText: "Explain more clearly"
 )
 ))
 XCTAssertEqual(referentialCompilation.selectedExampleModules, [PromptExampleModuleID.referentialFollowup])
 XCTAssertTrue(referentialCompilation.rendered.contains("Example: referential follow-up"))

 // identity probe overrides upstream
 // classification. T16 device-log shape `Tell me about yourself`
 // is classified `.question`; the identity-question example
 // module is selected anyway via the latestUserText short-circuit.
 let identityCompilation = PromptCompiler.compile(makeInput(
 turnOverlay: makeOverlay(
 classification: .question,
 latestUserText: "Tell me about yourself"
 )
 ))
 XCTAssertEqual(identityCompilation.selectedExampleModules, [PromptExampleModuleID.identityQuestion])
 XCTAssertTrue(identityCompilation.rendered.contains("Example: identity question"))
 }

 func test_promptCompiler_doesNotInjectExampleBankForCloudOrToolSpecialist() {
 for profileID in [PromptProfileID.geminiCloud, .functionGemmaTool] {
 let compilation = PromptCompiler.compile(makeInput(
 profileID: profileID,
 turnOverlay: makeOverlay(
 classification: .factRecallUnknown,
 latestUserText: "What is my name?"
 )
 ))
 XCTAssertEqual(compilation.selectedExampleModules, [])
 XCTAssertFalse(compilation.sections.contains(where: { $0.layer == .exampleBank }))
 XCTAssertFalse(compilation.rendered.contains("# Current-turn examples"))
 }
 }

 func test_contextBuilder_promptCompilerPath_matchesLegacyAssembly() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("What does the launch plan cover?")])),
 ],
 turnCount: 1
 )
 let extraSystemContext = ["workspace": "/tmp/demo", "mode": "voice"]

 let request = await builder.build(
 state: state,
 enabledToolNames: ["memory_write"],
 environment: environment,
 extraSystemContext: extraSystemContext,
 tools: [],
 options: .init()
 )
 let reducedMessages = builder.reducer.reduce(state.messages)
 let (pipelined, _) = builder.pipeline.transform(reducedMessages)

 let expected = legacyAssembly(
 enabledToolNames: ["memory_write"],
 environment: environment,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: extraSystemContext,
 currentTurnFocus: builder.currentTurnFocusForTesting(from: pipelined)
 )

 XCTAssertEqual(request.systemPrompt, expected)
 }

 func test_contextBuilder_buildCompiledTurn_matchesLegacyRequestAssembly() async {
 let builder = ContextBuilder(memoryStore: nil)
 let tool = EmptyTool
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("What does the launch plan cover?")]))
 ],
 turnCount: 1
 )
 let extraSystemContext = ["workspace": "/tmp/demo", "mode": "voice"]

 let compiled = await builder.buildCompiledTurn(
 turnID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
 sessionID: "session-123",
 state: state,
 enabledToolNames: ["empty"],
 environment: environment,
 extraSystemContext: extraSystemContext,
 toolCatalog: [tool.catalogEntry(source: .builtin)],
 options: .init()
 )
 let legacy = await builder.build(
 state: state,
 enabledToolNames: ["empty"],
 environment: environment,
 extraSystemContext: extraSystemContext,
 tools: [tool],
 options: .init()
 )
 let adapted = ModelRequest(compiledTurn: compiled, tools: [tool])

 XCTAssertEqual(compiled.sessionID, "session-123")
 XCTAssertEqual(compiled.profileID, .gemmaLocal)
 XCTAssertEqual(compiled.messages, legacy.messages)
 XCTAssertEqual(compiled.promptAssembly.rendered, legacy.systemPrompt)
 XCTAssertEqual(compiled.diagnostics.promptAssembly, compiled.promptAssembly)
 XCTAssertEqual(compiled.diagnostics.turnOverlay, compiled.bindingContext)
 XCTAssertEqual(compiled.diagnostics.currentTurnFocus, builder.currentTurnFocusForTesting(from: compiled.messages))
 XCTAssertEqual(compiled.hostOptions.toolMode, .allowed)
 XCTAssertEqual(adapted.messages, legacy.messages)
 XCTAssertEqual(adapted.systemPrompt, legacy.systemPrompt)
 XCTAssertEqual(adapted.wasTruncated, legacy.wasTruncated)
 }

 private func makeInput(
 profileID: PromptProfileID = .gemmaLocal,
 enabledToolNames: Set<String> = [],
 memoryIndex: String? = nil,
 memoryTopics: [String: String] = [:],
 extraSystemContext: [String: String] = [:],
 currentTurnFocus: String? = nil,
 turnOverlay: TurnOverlayBundle? = nil
 ) -> PromptCompiler.Input {
 .init(
 profileID: profileID,
 enabledToolNames: enabledToolNames,
 environment: environment,
 memoryIndex: memoryIndex,
 memoryTopics: memoryTopics,
 extraSystemContext: extraSystemContext,
 turnOverlay: turnOverlay,
 currentTurnFocus: currentTurnFocus,
 recoveryNotes: nil
 )
 }

 private func makeOverlay(
 classification: TurnClassification,
 latestUserText: String,
 visibleFacts: [VisibleFactRecord] = []
 ) -> TurnOverlayBundle {
 TurnOverlayBundle(
 classification: classification,
 bindingPriority: visibleFacts.isEmpty ? .latestTurnOnly : .latestTurnWithVisibleFacts,
 latestUserText: latestUserText,
 visibleFacts: visibleFacts,
 recentTail: [],
 retrievalArtifacts: [],
 summarySnippet: nil,
 instructions: []
 )
 }

 private func assertParity(for input: PromptCompiler.Input, file: StaticString = #filePath, line: UInt = #line) {
 let compilation = PromptCompiler.compile(input)
 let legacy = legacyAssembly(
 enabledToolNames: input.enabledToolNames,
 environment: input.environment,
 memoryIndex: input.memoryIndex,
 memoryTopics: input.memoryTopics,
 extraSystemContext: input.extraSystemContext,
 currentTurnFocus: input.currentTurnFocus
 )
 XCTAssertEqual(compilation.rendered, legacy, file: file, line: line)
 }

 // MARK: - R7-A tool-description tests

 func test_toolsSection_rendersDescriptionsWhenProvided() {
 let input = PromptCompiler.Input(
 profileID: .gemmaLocal,
 enabledToolNames: ["calendar_list_events", "memory_write"],
 toolDescriptions: [
 "calendar_list_events": "List upcoming calendar events within a date range. Defaults to next 7 days.",
 "memory_write": "Save a durable fact to long-term memory. Requires explicit user request."
 ],
 environment: environment,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: [:]
 )
 let rendered = PromptCompiler.compile(input).rendered
 XCTAssertTrue(
 rendered.contains(" - calendar_list_events: List upcoming calendar events within a date range."),
 "first-sentence description should be rendered after the name + colon"
 )
 XCTAssertTrue(
 rendered.contains(" - memory_write: Save a durable fact to long-term memory."),
 "second tool's description should also render"
 )
 XCTAssertTrue(
 rendered.contains("make all independent tool calls in parallel"),
 "parallelization guidance should be present in tools section"
 )
 }

 func test_toolsSection_fallsBackToNameWhenNoDescription() {
 let input = PromptCompiler.Input(
 profileID: .gemmaLocal,
 enabledToolNames: ["unknown_tool"],
 toolDescriptions: [:],
 environment: environment,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: [:]
 )
 let rendered = PromptCompiler.compile(input).rendered
 // Name-only bullet — no colon form.
 XCTAssertTrue(rendered.contains(" - unknown_tool"))
 XCTAssertFalse(
 rendered.contains(" - unknown_tool:"),
 "no description → name-only bullet, no colon"
 )
 }

 func test_toolsSection_capsDescriptionAtOneHundredTwentyChars() {
 let longDesc = String(repeating: "x", count: 200) + ". second sentence."
 let input = PromptCompiler.Input(
 profileID: .gemmaLocal,
 enabledToolNames: ["long_tool"],
 toolDescriptions: ["long_tool": longDesc],
 environment: environment,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: [:]
 )
 let rendered = PromptCompiler.compile(input).rendered
 // Find the line and assert it's bounded.
 let line = rendered.split(separator: "\n").first(where: { $0.contains(" - long_tool:") })
 XCTAssertNotNil(line)
 // Line = " - long_tool: <desc>." — the description portion must be ≤ 120 + "…" + "."
 XCTAssertLessThan(
 (line?.count ?? 0), 150,
 "long descriptions should be truncated with ellipsis; got \(line ?? "")"
 )
 XCTAssertTrue(line?.contains("…") == true, "truncation mark must be present")
 }

 // MARK: - R7-A++ hotfix — robust description rendering

 /// tools like GlobTool have descriptions that
 /// start with "- " (their own bullet) and span multiple `\n`-separated
 /// bullet points. The rendered bullet must NOT leak the `\n` or the
 /// leading `- ` into the prompt.
 func test_toolsSection_cleansMultiBulletDescription() {
 let multiBullet = """
 - Fast file pattern matching tool that works with any codebase size
 - Supports glob patterns
 - Returns matching file paths
 """
 let input = PromptCompiler.Input(
 profileID: .gemmaLocal,
 enabledToolNames: ["glob"],
 toolDescriptions: ["glob": multiBullet],
 environment: environment,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: [:]
 )
 let rendered = PromptCompiler.compile(input).rendered
 let line = rendered.split(separator: "\n").first(where: { $0.contains(" - glob:") })
 XCTAssertNotNil(line)
 let lineStr = String(line ?? "")
 // The cleaning pipeline should produce exactly ONE sentence on one line.
 XCTAssertEqual(
 lineStr,
 " - glob: Fast file pattern matching tool that works with any codebase size.",
 "multi-bullet description should render as a single clean sentence; got: \(lineStr)"
 )
 // And the rendered prompt must not contain the raw `\n- Supports`
 // stream-in that would otherwise bleed into the next bullet.
 XCTAssertFalse(
 rendered.contains(" - glob: - Fast"),
 "leading bullet marker must not slip through into the rendered description"
 )
 }

 /// the old `split(separator: ".")` truncated
 /// descriptions like `"Fast glob for **/*.tsx files."` mid-word at
 /// the period inside `".tsx"`. The fixed pipeline splits on `". "`
 /// (period + space) so only real sentence boundaries cut the output.
 func test_toolsSection_doesNotBreakOnPeriodInsideQuotes() {
 let tricky = "Fast glob for **/*.tsx files, returns paths."
 let input = PromptCompiler.Input(
 profileID: .gemmaLocal,
 enabledToolNames: ["glob"],
 toolDescriptions: ["glob": tricky],
 environment: environment,
 memoryIndex: nil,
 memoryTopics: [:],
 extraSystemContext: [:]
 )
 let rendered = PromptCompiler.compile(input).rendered
 let line = rendered.split(separator: "\n").first(where: { $0.contains(" - glob:") })
 XCTAssertNotNil(line)
 let lineStr = String(line ?? "")
 XCTAssertTrue(
 lineStr.contains("**/*.tsx files"),
 "period inside the filename must not split the sentence early; got: \(lineStr)"
 )
 }

 private func legacyAssembly(
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 memoryIndex: String?,
 memoryTopics: [String: String],
 extraSystemContext: [String: String],
 currentTurnFocus: String?
 ) -> String {
 var sections = SystemPrompt.build(
 enabledToolNames: enabledToolNames,
 environment: environment,
 memoryIndex: memoryIndex,
 memoryTopics: memoryTopics
 )
 sections = SystemPrompt.appendSystemContext(sections, extraSystemContext)
 if let currentTurnFocus {
 sections.append(currentTurnFocus)
 }
 return sections.joined(separator: "\n\n")
 }
}
