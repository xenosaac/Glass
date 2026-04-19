import Foundation

internal struct ContextBuildArtifacts: Sendable {
 let request: ModelRequest
 let retrievalQuery: String?
 let retrievalDecision: RetrievalDecision
 let promptAssembly: PromptAssembly
 let turnOverlay: TurnOverlayBundle?
 let currentTurnFocus: String?
}

private struct ContextBindingCompiler: Sendable {
 private static let summaryRelevantPhrases: [String] = [
 "what are we working on",
 "what am i working on",
 "what are we doing",
 "what is the status",
 "what s the status",
 "summarize the project",
 "summarize our progress",
 "recap where we are",
 "what have we done",
 "what did we do",
 "what do we know so far",
 "remind me what we",
 "continue where we left off",
 "pick up where we left off",
 "what is the context",
 "what s the context",
 "where were we"
 ]

 private static let summaryRelevantTerms: Set<String> = [
 "project", "status", "progress", "context", "recap",
 "summary", "summarize", "continue", "resume",
 "roadmap", "working", "doing", "conversation", "history", "thread"
 ]
 private static let assistantIdentityPhrases: [String] = [
 "what is your name",
 "what s your name",
 "whats your name",
 "who are you",
 "what should i call you",
 "how should i address you",
 "what do i call you"
 ]

 func compile(
 messages: [RelayMessage],
 state: AgentSessionState,
 analysis: TurnAnalysis?,
 classifier: TurnClassifier,
 retrievalDecision: RetrievalDecision
 ) -> TurnOverlayBundle? {
 guard let analysis,
 let lastUserIndex = lastNonMetaUserIndex(in: messages),
 let latestUserText = TurnClassifier.userText(from: messages[lastUserIndex]) else {
 return nil
 }

 let visibleFacts = shouldIncludeVisibleFacts(for: analysis)
 ? resolveVisibleFacts(
 analysis: analysis,
 messages: messages,
 lastUserIndex: lastUserIndex,
 classifier: classifier
 )
 : []
 let recentTail = shouldIncludeRecentTail(for: analysis)
 ? resolveRecentTail(
 analysis: analysis,
 messages: messages,
 lastUserIndex: lastUserIndex,
 classifier: classifier,
 visibleFacts: visibleFacts
 )
 : []
 let retrievalArtifacts = resolveArtifactInjection(
 for: analysis,
 decision: retrievalDecision
 )
 let summarySnippet = resolveSummarySnippet(for: analysis, state: state)

 return TurnOverlayBundle(
 classification: analysis.classification,
 bindingPriority: bindingPriority(
 visibleFacts: visibleFacts,
 recentTail: recentTail,
 retrievalArtifacts: retrievalArtifacts
 ),
 latestUserText: latestUserText,
 visibleFacts: visibleFacts,
 recentTail: recentTail,
 retrievalArtifacts: retrievalArtifacts,
 summarySnippet: summarySnippet,
 instructions: bindingInstructions(
 analysis: analysis,
 visibleFacts: visibleFacts,
 retrievalArtifacts: retrievalArtifacts,
 summarySnippet: summarySnippet
 )
 )
 }

 private func shouldIncludeVisibleFacts(for analysis: TurnAnalysis) -> Bool {
 switch analysis.classification {
 case .factRecallKnown, .factRecallUnknown, .repairCue:
 return true
 case .question, .declarativeFact, .socialOpener, .referentialFollowup, .transportCheck, .toolFollowup, .ambiguous:
 return false
 }
 }

 private func shouldIncludeRecentTail(for analysis: TurnAnalysis) -> Bool {
 switch analysis.classification {
 case .question, .factRecallKnown, .factRecallUnknown, .repairCue, .referentialFollowup, .toolFollowup:
 return true
 case .declarativeFact, .socialOpener, .transportCheck, .ambiguous:
 return false
 }
 }

 private func resolveVisibleFacts(
 analysis: TurnAnalysis,
 messages: [RelayMessage],
 lastUserIndex: Int,
 classifier: TurnClassifier
 ) -> [VisibleFactRecord] {
 guard !analysis.visibleFactTexts.isEmpty else { return [] }

 var unresolved = analysis.visibleFactTexts
 var resolved: [VisibleFactRecord] = []
 for i in stride(from: lastUserIndex - 1, through: 0, by: -1) {
 guard let text = TurnClassifier.userText(from: messages[i]),
 let textIndex = unresolved.lastIndex(of: text) else {
 continue
 }
 guard let priorAnalysis = classifier.analyze(messages: Array(messages.prefix(i + 1))),
 priorAnalysis.classification == .declarativeFact else {
 continue
 }

 resolved.append(
 VisibleFactRecord(
 text: text,
 sourceTurnIndex: i,
 sourceClassification: .declarativeFact
 )
 )
 unresolved.remove(at: textIndex)
 if unresolved.isEmpty { break }
 }

 return resolved.reversed()
 }

 private func resolveRecentTail(
 analysis: TurnAnalysis,
 messages: [RelayMessage],
 lastUserIndex: Int,
 classifier: TurnClassifier,
 visibleFacts: [VisibleFactRecord]
 ) -> [BoundConversationTurn] {
 switch analysis.classification {
 case .declarativeFact, .socialOpener, .transportCheck, .ambiguous:
 return []

 case .factRecallKnown, .factRecallUnknown:
 guard let firstVisibleFactIndex = visibleFacts.first?.sourceTurnIndex else {
 return []
 }
 let slice = Array(messages[firstVisibleFactIndex..<lastUserIndex])
 let relevantTerms = analysis.salientTerms.union(
 visibleFacts.reduce(into: Set<String>()) { acc, fact in
 acc.formUnion(TurnClassifier.salientTerms(in: fact.text))
 }
 )
 let turns = conversationalTurns(from: slice).filter { turn in
 if turn.role == "user", visibleFacts.contains(where: { $0.text == turn.text }) {
 return true
 }
 return !turn.text.isEmpty
 && !relevantTerms.isEmpty
 && !TurnClassifier.salientTerms(in: turn.text).intersection(relevantTerms).isEmpty
 }
 return Array(turns.suffix(3))

 case .repairCue, .referentialFollowup, .toolFollowup, .question:
 return classifier.recentConversationTail(for: analysis, in: messages)
 .map { BoundConversationTurn(role: $0.role, text: $0.text) }
 }
 }

 private func resolveArtifactInjection(
 for analysis: TurnAnalysis,
 decision: RetrievalDecision
 ) -> [ScoredContextArtifact] {
 guard analysis.classification == .question else { return [] }
 return decision.artifacts
 }

 private func resolveSummarySnippet(
 for analysis: TurnAnalysis,
 state: AgentSessionState
 ) -> String? {
 guard analysis.classification == .question,
 let summary = state.summaryState.latestBoundarySummary?
 .trimmingCharacters(in: .whitespacesAndNewlines),
 !summary.isEmpty,
 isSummaryRelevantQuestion(analysis) else {
 return nil
 }

 let clipped = String(summary.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
 return clipped.isEmpty ? nil : clipped
 }

 private func bindingPriority(
 visibleFacts: [VisibleFactRecord],
 recentTail: [BoundConversationTurn],
 retrievalArtifacts: [ScoredContextArtifact]
 ) -> BindingPriority {
 if !retrievalArtifacts.isEmpty && !visibleFacts.isEmpty {
 return .latestTurnWithFactsAndRetrieval
 }
 if !retrievalArtifacts.isEmpty {
 return .latestTurnWithRetrieval
 }
 if !visibleFacts.isEmpty {
 return .latestTurnWithVisibleFacts
 }
 if !recentTail.isEmpty {
 return .latestTurnWithRecentTail
 }
 return .latestTurnOnly
 }

 private func bindingInstructions(
 analysis: TurnAnalysis,
 visibleFacts: [VisibleFactRecord],
 retrievalArtifacts: [ScoredContextArtifact],
 summarySnippet: String?
 ) -> [String] {
 var instructions = [
 "Answer the latest user message before using any supporting context.",
 "The latest user message below is visible and non-empty. Do not say it was empty, missed, or unavailable."
 ]
 if isAssistantIdentityQuestion(analysis.normalizedLatestText) {
 instructions.append("The user is asking for your assistant name or how to address you. Answer \"Glass\". Do not answer with the model or provider name like \"Gemma 4\" or \"Gemini\".")
 }
 if analysis.classification == .factRecallKnown || analysis.classification == .factRecallUnknown {
 if visibleFacts.isEmpty {
 instructions.append("No visible fact currently answers this recall question. Say you do not know it yet and invite the user to tell you. Do not switch to generic help text.")
 instructions.append("Do not reply with generic next-step boilerplate like \"How can I help you today?\" or \"Please tell me what you would like to do next.\"")
 } else {
 instructions.append("A visible fact already answers this recall question. Restate that fact directly.")
 instructions.append("Do not ask the user to repeat the fact, and do not answer with uncertainty.")
 }
 }
 if analysis.classification == .socialOpener {
 instructions.append("A warmer two-to-four sentence reply is appropriate here, and one light follow-up is allowed.")
 instructions.append("Do not call the message open-ended, do not ask for more context, and do not fall back to attachment or image prompts.")
 }
 if analysis.classification == .referentialFollowup {
 instructions.append("Treat the immediately previous answer as the referent for this clarification turn unless the focus section says otherwise.")
 }
 if !visibleFacts.isEmpty {
 instructions.append("Use visible facts only if they directly answer the latest turn.")
 }
 if !retrievalArtifacts.isEmpty {
 instructions.append("Use retrieved context only to support the latest question.")
 }
 if summarySnippet != nil {
 instructions.append("Use compacted history only as background, not as the answer.")
 }
 return instructions
 }

 private func isSummaryRelevantQuestion(_ analysis: TurnAnalysis) -> Bool {
 let normalized = analysis.normalizedLatestText
 if Self.summaryRelevantPhrases.contains(where: { normalized.contains($0) }) {
 return true
 }

 let termHits = analysis.salientTerms.intersection(Self.summaryRelevantTerms)
 guard !termHits.isEmpty else { return false }

 let referentialCues = [
 " we ", " our ", " this ", " that ", " it ",
 " again ", " so far ", " left off "
 ]
 if referentialCues.contains(where: { normalized.contains($0) }) {
 return true
 }

 return analysis.latestUserText.count >= 48
 }

 private func isAssistantIdentityQuestion(_ normalizedLatestText: String) -> Bool {
 Self.assistantIdentityPhrases.contains(where: { normalizedLatestText.contains($0) })
 }

 private func lastNonMetaUserIndex(in messages: [RelayMessage]) -> Int? {
 for i in stride(from: messages.count - 1, through: 0, by: -1) {
 if case .user(let content) = messages[i], !content.isMeta {
 return i
 }
 }
 return nil
 }

 private func conversationalTurns(from messages: [RelayMessage]) -> [BoundConversationTurn] {
 messages.compactMap { message in
 switch message {
 case .user(let content):
 guard !content.isMeta,
 let text = TurnClassifier.userText(from: message) else {
 return nil
 }
 return BoundConversationTurn(role: "user", text: text)

 case .assistant(let content):
 let text = content.blocks.compactMap { block -> String? in
 if case .text(let value) = block { return value }
 return nil
 }
 .joined(separator: " ")
 .trimmingCharacters(in: .whitespacesAndNewlines)
 guard !text.isEmpty else { return nil }
 return BoundConversationTurn(role: "assistant", text: text)

 case .toolResult(let blocks):
 let text = blocks
 .map(\.output)
 .joined(separator: "\n")
 .trimmingCharacters(in: .whitespacesAndNewlines)
 guard !text.isEmpty else { return nil }
 return BoundConversationTurn(role: "tool", text: text)
 }
 }
 }
}

internal struct FocusSectionRenderer: Sendable {
 /// Render a terse focus section for the system prompt. Prompt-surgery pass
 /// dropped abstract fields — binding priority, required behavior,
 /// turn-specific instructions, recent tail, summary snippet, latest user
 /// message anchor — that a 2B CPU model cannot act on reliably; those rules
 /// are now carried by `exampleBankSection` as few-shot examples. Kept: the
 /// `# Current turn focus` header, `- Turn classification:` prefix, and the
 /// factual blocks (`Latest visible facts:`, `Retrieved context available
 /// for this turn:`). Field names stay backward-compatible with existing
 /// harness test assertions where feasible.
 func render(_ turnOverlay: TurnOverlayBundle?) -> String? {
 guard let turnOverlay else {
 return nil
 }

 var lines: [String] = [
 "# Current turn focus",
 "- Turn classification: \(turnOverlay.classification.rawValue)",
 ]

 if !turnOverlay.visibleFacts.isEmpty {
 lines.append("")
 lines.append("Latest visible facts:")
 lines.append(contentsOf: turnOverlay.visibleFacts.map { "- \($0.text)" })
 } else if turnOverlay.classification == .factRecallUnknown {
 lines.append("")
 lines.append("Latest visible facts:")
 lines.append("- none available for this turn")
 }

 if !turnOverlay.retrievalArtifacts.isEmpty {
 lines.append("")
 lines.append("Retrieved context available for this turn:")
 lines.append(contentsOf: turnOverlay.retrievalArtifacts.map { artifact in
 let source = artifact.artifact.sourceDisplayName
 switch (artifact.artifact.position, artifact.artifact.totalParts) {
 case let (.some(position), .some(totalParts)):
 return "- [\(artifact.artifact.kind.rawValue)] \(source) (part \(position + 1)/\(totalParts))"
 default:
 return "- [\(artifact.artifact.kind.rawValue)] \(source)"
 }
 })
 }

 return lines.joined(separator: "\n")
 }
}

/// Per-turn assembly orchestrator. Takes the current message history
/// plus session config and returns a fully-assembled `ModelRequest`
/// ready to hand to a `ModelClient`.
///
/// pure move of the per-iteration assembly block from the
/// former `AgentCore.runTurn` body (lines 211–258 pre-carve). Memory
/// loading + system-prompt composition + message pipeline run in the
/// same order they did inline. No compaction, tool-result budgeter,
/// retrieval planning, or attachment indexing in this phase — those
/// are /E/F extensions that land inside this struct later
/// without requiring a new public type.
public struct ContextBuilder: Sendable {

 public let memoryStore: MemoryStore?
 public let pipeline: MessagePipeline
 public let reducer: ToolResultReducer
 public let attachmentStore: AttachmentStore?
 public let workspaceURL: URL?
 public let fileProvider: (any FileProviderService)?
 public let retrievalPlanner: RetrievalPlanner

 public init(
 memoryStore: MemoryStore?,
 pipeline: MessagePipeline = MessagePipeline(),
 reducer: ToolResultReducer = ToolResultReducer(),
 attachmentStore: AttachmentStore? = nil,
 workspaceURL: URL? = nil,
 fileProvider: (any FileProviderService)? = nil,
 retrievalPlanner: RetrievalPlanner = RetrievalPlanner()
 ) {
 self.memoryStore = memoryStore
 self.pipeline = pipeline
 self.reducer = reducer
 self.attachmentStore = attachmentStore
 self.workspaceURL = workspaceURL
 self.fileProvider = fileProvider
 self.retrievalPlanner = retrievalPlanner
 }

 // MARK: - Tool-mode selection (DEBUG.md F2)

 /// Decide `HostExecutionOptions.toolMode` for this turn.
 ///
 /// Exhaustive decision matrix:
 /// empty catalog -> `.disabled` (preserves pre-fix behavior).
 /// non-empty catalog + no analysis -> `.allowed` (no latest user text to classify).
 /// non-empty catalog + tool-intent analysis -> `.required` (force primary into tool emission).
 /// non-empty catalog + non-tool-intent analysis -> `.allowed` (pre-fix behavior preserved).
 private static func selectToolMode(
 analysis: TurnAnalysis?,
 toolCatalog: [ToolCatalogEntry]
 ) -> HostToolMode {
 guard !toolCatalog.isEmpty else { return .disabled }
 guard let analysis else { return .allowed }
 if TurnClassifier.isToolIntent(latestUserText: analysis.latestUserText) {
 return .required
 }
 return .allowed
 }

 /// Assemble a complete `ModelRequest` for one model call.
 ///
 /// Behavior parity requirements:
 /// `systemPrompt` equals the former `systemPromptString` built at
 /// `AgentCore.runTurn:220–230` for the same inputs.
 /// `messages` equal the former `messagesWithContext` built at
 /// `AgentCore.runTurn:252–258` for the same inputs.
 /// `tools` and `options` pass through unchanged.
 ///
 /// takes `state: AgentSessionState` instead of a raw
 /// `messages` array, making the separation between "session
 /// state" and "recent-history working window" explicit.
 /// `state.messages` is the recent-history input to the pipeline;
 /// `turnCount` is not read here today but is available for future
 /// compactor / budgeter logic in /E.
 public func build(
 state: AgentSessionState,
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions
 ) async -> ModelRequest {
 let artifacts = await buildArtifacts(
 state: state,
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 tools: tools,
 options: options
 )
 return artifacts.request
 }

 internal func buildCompiledTurn(
 turnID: UUID,
 sessionID: String,
 state: AgentSessionState,
 currentTurn: NormalizedTurn? = nil,
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 toolCatalog: [ToolCatalogEntry],
 options: CactusModelHost.CompletionOptions
 ) async -> CompiledTurnRequest {
 let resolved = await resolveTurnContext(
 turnID: turnID,
 sessionID: sessionID,
 state: state,
 currentTurn: currentTurn,
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 toolCatalog: toolCatalog,
 options: options
 )
 return resolved.compiledTurn
 }

 internal func buildArtifacts(
 state: AgentSessionState,
 currentTurn: NormalizedTurn? = nil,
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 tools: [any RelayTool],
 options: CactusModelHost.CompletionOptions
 ) async -> ContextBuildArtifacts {
 let resolved = await resolveTurnContext(
 turnID: UUID(),
 sessionID: "legacy-session",
 state: state,
 currentTurn: currentTurn,
 enabledToolNames: enabledToolNames,
 environment: environment,
 extraSystemContext: extraSystemContext,
 toolCatalog: tools.map { $0.catalogEntry(source: .other) },
 options: options
 )

 return ContextBuildArtifacts(
 request: ModelRequest(compiledTurn: resolved.compiledTurn, tools: tools),
 retrievalQuery: resolved.retrievalDecision.query,
 retrievalDecision: resolved.retrievalDecision,
 promptAssembly: resolved.compiledTurn.promptAssembly,
 turnOverlay: resolved.compiledTurn.bindingContext,
 currentTurnFocus: resolved.compiledTurn.diagnostics.currentTurnFocus
 )
 }

 internal func compilePrompt(_ input: PromptAssemblyInput) -> PromptAssembly {
 let compiler = PromptCompiler()
 return compiler.compile(input)
 }

 internal func currentTurnFocusForTesting(from messages: [RelayMessage]) -> String? {
 let classifier = TurnClassifier()
 let turnOverlay = ContextBindingCompiler().compile(
 messages: messages,
 state: AgentSessionState.hydrated(from: messages),
 analysis: classifier.analyze(messages: messages),
 classifier: classifier,
 retrievalDecision: RetrievalDecision(query: nil, artifacts: [])
 )
 return FocusSectionRenderer().render(turnOverlay)
 }

 internal func turnOverlayForTesting(from messages: [RelayMessage]) -> TurnOverlayBundle? {
 let classifier = TurnClassifier()
 return ContextBindingCompiler().compile(
 messages: messages,
 state: AgentSessionState.hydrated(from: messages),
 analysis: classifier.analyze(messages: messages),
 classifier: classifier,
 retrievalDecision: RetrievalDecision(query: nil, artifacts: [])
 )
 }

 private func injectContextArtifacts(
 _ artifacts: [ScoredContextArtifact],
 into messages: [RelayMessage]
 ) -> [RelayMessage] {
 guard let lastUserIdx = lastNonMetaUserIndex(in: messages) else {
 return messages
 }

 guard !artifacts.isEmpty else { return messages }

 var out = messages
 out.insert(contentsOf: artifacts.map { MessageFactory.contextArtifact($0.artifact) }, at: lastUserIdx)
 return out
 }

 private func lastNonMetaUserIndex(in messages: [RelayMessage]) -> Int? {
 for i in stride(from: messages.count - 1, through: 0, by: -1) {
 if case .user(let content) = messages[i], !content.isMeta {
 return i
 }
 }
 return nil
 }

 private func resolveTurnContext(
 turnID: UUID,
 sessionID: String,
 state: AgentSessionState,
 currentTurn: NormalizedTurn?,
 enabledToolNames: Set<String>,
 environment: SystemPrompt.Environment,
 extraSystemContext: [String: String],
 toolCatalog: [ToolCatalogEntry],
 options: CactusModelHost.CompletionOptions
 ) async -> (compiledTurn: CompiledTurnRequest, retrievalDecision: RetrievalDecision) {
 let messages = messagesWithCanonicalCurrentTurn(
 state.messages,
 currentTurn: currentTurn
 )
 // load index AND topic bodies.
 // Initialize the cold-start MEMORY.md stub via loadIndex's
 // `initializeIfMissing: true` so the system prompt always carries
 // the full memory section (instructions + index + topic bodies)
 // instead of falling into the 30-token minimal stub branch when
 // the file doesn't exist yet. Topic bodies come from
 // loadRetrievalDocuments (frontmatter pre-stripped) and are
 // keyed by the parsed displayName so SystemPrompt can render
 // `### <displayName>\n<body>` without doing any frontmatter
 // parsing of its own.
 let memoryIndex: String?
 let memoryTopics: [String: String]
 if let store = memoryStore {
 memoryIndex = (await store.loadIndex(initializeIfMissing: true)) ?? ""
 let docs = await store.loadRetrievalDocuments(budgetBytes: 8_000)
 var formatted: [String: String] = [:]
 for doc in docs {
 let key = doc.displayName.isEmpty
 ? doc.fileName.replacingOccurrences(of: ".md", with: "")
 : doc.displayName
 formatted[key] = doc.body
 }
 memoryTopics = formatted
 } else {
 memoryIndex = nil
 memoryTopics = [:]
 }

 let reducedMessages = reducer.reduce(messages)
 let (pipelined, wasTruncated) = pipeline.transform(reducedMessages)

 let classifier = TurnClassifier()
 let analysis = classifier.analyze(messages: pipelined)
 let plannedRetrievalDecision = await retrievalPlanner.plan(
 analysis: analysis,
 memoryStore: memoryStore,
 attachmentStore: attachmentStore,
 workspaceURL: workspaceURL,
 fileProvider: fileProvider
 )
 let turnOverlay = ContextBindingCompiler().compile(
 messages: pipelined,
 state: state,
 analysis: analysis,
 classifier: classifier,
 retrievalDecision: plannedRetrievalDecision
 )
 let finalMessages = injectContextArtifacts(
 turnOverlay?.retrievalArtifacts ?? [],
 into: pipelined
 )
 let modelMessages = TurnIngressNormalizer.projectMessagesForModel(
 finalMessages,
 overridingLatestUserMessage: currentTurn?.modelMessage
 )
 let effectiveRetrievalDecision = RetrievalDecision(
 query: plannedRetrievalDecision.query,
 artifacts: turnOverlay?.retrievalArtifacts ?? []
 )
 let currentTurnFocus = FocusSectionRenderer().render(turnOverlay)
 // build the per-tool description map from
 // the catalog so SystemPrompt.toolsSection can render selection
 // cues the way CC does in `prompts.ts:269-314`. `entry.title` is
 // set to `tool.description` in `RelayTool.catalogEntry(source:)`.
 var toolDescriptions: [String: String] = [:]
 for entry in toolCatalog where enabledToolNames.contains(entry.name) {
 toolDescriptions[entry.name] = entry.title
 }
 let promptAssembly = compilePrompt(
 .init(
 profileID: .gemmaLocal,
 enabledToolNames: enabledToolNames,
 toolDescriptions: toolDescriptions,
 environment: environment,
 memoryIndex: memoryIndex,
 memoryTopics: memoryTopics,
 extraSystemContext: extraSystemContext,
 turnOverlay: turnOverlay,
 currentTurnFocus: currentTurnFocus
 )
 )

 let retrievalSummary = AgentSessionState.retrievalDecisionSummary(from: effectiveRetrievalDecision)
 let hostOptions = HostExecutionOptions(
 completionOptions: options,
 toolMode: Self.selectToolMode(analysis: analysis, toolCatalog: toolCatalog),
 emitVisibleTokens: true,
 allowCloudHandoff: true
 )
 let diagnostics = CompiledTurnDiagnostics(
 promptAssembly: promptAssembly,
 turnOverlay: turnOverlay,
 currentTurnFocus: currentTurnFocus,
 latestNonMetaUserText: turnOverlay?.latestUserText ?? lastNonMetaUserText(in: modelMessages),
 turnClassification: turnOverlay?.classification,
 retrievalQuery: effectiveRetrievalDecision.query,
 retrievalDecision: retrievalSummary
 )
 let compiledTurn = CompiledTurnRequest(
 turnID: turnID,
 sessionID: sessionID,
 profileID: .gemmaLocal,
 messages: modelMessages,
 promptAssembly: promptAssembly,
 toolCatalog: toolCatalog,
 hostOptions: hostOptions,
 wasTruncated: wasTruncated,
 retrievalPlan: retrievalSummary,
 bindingContext: turnOverlay,
 recoveryPlan: state.recoveryState,
 diagnostics: diagnostics
 )
 return (compiledTurn, effectiveRetrievalDecision)
 }

 private func messagesWithCanonicalCurrentTurn(
 _ messages: [RelayMessage],
 currentTurn: NormalizedTurn?
 ) -> [RelayMessage] {
 guard let currentTurn,
 let lastUserIndex = lastNonMetaUserIndex(in: messages) else {
 return messages
 }

 var canonical = messages
 canonical[lastUserIndex] = currentTurn.transcriptMessage
 return canonical
 }

 private func lastNonMetaUserText(in messages: [RelayMessage]) -> String? {
 guard let lastUserIndex = lastNonMetaUserIndex(in: messages) else { return nil }
 return TurnClassifier.userText(from: messages[lastUserIndex])
 }
}
