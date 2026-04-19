import XCTest
@testable import Relay

/// Pure-function tests for the agent harness invariants.
///
/// Each test asserts a specific claim from the reference agent's source so the
/// provenance of the expected behavior is auditable — when someone asks
/// "why is this the expected shape?", the answer is always "because CC
/// does it this way at <file>:<line>". No device, no model calls, no file
/// I/O except inside a temp dir for MemoryStore tests.
final class HarnessTests: XCTestCase {

 // MARK: - ensureToolResultPairing

 /// CC `utils/messages.ts:5391-5397`: when an assistant's `tool_use` has
 /// no matching `tool_result` in the following user message, inject a
 /// synthetic `ToolResultBlockParam` with `is_error: true` and content
 /// `[Tool result missing due to internal error]`.
 func test_ensureToolResultPairing_injectsSyntheticForMissingResult() {
 let orphan = ToolUseBlock(id: "call_A", name: "get_current_datetime", inputJson: "{}")
 let input: [RelayMessage] = [
 .user(UserContent(blocks: [.text("what time is it?")])),
 .assistant(AssistantContent(blocks: [.toolUse(orphan)])),
 ]

 let (repaired, hadRepairs) = CactusModelHost.ensureToolResultPairing(input)

 XCTAssertTrue(hadRepairs)
 XCTAssertEqual(repaired.count, 3)
 guard case .toolResult(let results) = repaired[2] else {
 return XCTFail("expected synthetic tool_result message at index 2")
 }
 XCTAssertEqual(results.count, 1)
 XCTAssertEqual(results[0].toolUseId, "call_A")
 XCTAssertTrue(results[0].isError)
 XCTAssertEqual(results[0].output, MessageFactory.syntheticToolResultPlaceholder)
 }

 /// CC `utils/messages.ts:5305-5308`: a `tool_result` whose `tool_use_id`
 /// was never seen (orphan at turn start after truncation) is dropped.
 func test_ensureToolResultPairing_stripsOrphanedResults() {
 let orphan = ToolResultBlock(toolUseId: "call_ghost", output: "never called", isError: false)
 let input: [RelayMessage] = [
 .user(UserContent(blocks: [.text("hi")])),
 .toolResult([orphan]),
 ]

 let (repaired, hadRepairs) = CactusModelHost.ensureToolResultPairing(input)

 XCTAssertTrue(hadRepairs)
 XCTAssertEqual(repaired.count, 1)
 guard case .user = repaired[0] else {
 return XCTFail("expected lone user message after stripping orphan")
 }
 }

 /// CC `utils/messages.ts:5147-5232`: if the same `tool_use_id` appears
 /// in two assistant messages (a stream glitch or resume artifact), keep
 /// the first occurrence and drop duplicates.
 func test_ensureToolResultPairing_dedupesCrossMessageToolUseIds() {
 let first = ToolUseBlock(id: "call_A", name: "t", inputJson: "{}")
 let dup = ToolUseBlock(id: "call_A", name: "t", inputJson: "{}")
 let input: [RelayMessage] = [
 .user(UserContent(blocks: [.text("a")])),
 .assistant(AssistantContent(blocks: [.toolUse(first)])),
 .toolResult([ToolResultBlock(toolUseId: "call_A", output: "ok", isError: false)]),
 .user(UserContent(blocks: [.text("b")])),
 .assistant(AssistantContent(blocks: [.toolUse(dup), .text("hi")])),
 ]

 let (repaired, hadRepairs) = CactusModelHost.ensureToolResultPairing(input)

 XCTAssertTrue(hadRepairs)
 // The second assistant should no longer carry the duplicate tool_use.
 guard case .assistant(let content) = repaired[4] else {
 return XCTFail("expected assistant at index 4")
 }
 let toolUses = content.blocks.compactMap { block -> ToolUseBlock? in
 if case .toolUse(let use) = block { return use } else { return nil }
 }
 XCTAssertTrue(toolUses.isEmpty, "duplicate tool_use should be dropped; got \(toolUses)")
 }

 /// Well-formed input passes through unchanged.
 func test_ensureToolResultPairing_noOpOnWellFormedSequence() {
 let use = ToolUseBlock(id: "call_A", name: "t", inputJson: "{}")
 let input: [RelayMessage] = [
 .user(UserContent(blocks: [.text("hi")])),
 .assistant(AssistantContent(blocks: [.toolUse(use)])),
 .toolResult([ToolResultBlock(toolUseId: "call_A", output: "ok", isError: false)]),
 .user(UserContent(blocks: [.text("thanks")])),
 ]

 let (repaired, hadRepairs) = CactusModelHost.ensureToolResultPairing(input)

 XCTAssertFalse(hadRepairs)
 XCTAssertEqual(repaired.count, input.count)
 }

 // MARK: - MemoryStore

 /// Our own invariant: writing MEMORY.md with fewer
 /// `](file.md)` bullets than it currently has on disk throws
 /// `.indexDroppedEntries` with the set of missing lines. Turns silent
 /// data loss into a self-correcting error loop.
 func test_memoryStore_rejectsMemoryMdDrops() async throws {
 let tempDir = makeTempDir
 defer { try? FileManager.default.removeItem(at: tempDir) }
 let store = MemoryStore(root: tempDir)
 let original = """
 - [User](user_profile.md) — name: Isaac
 - [Testing](feedback_testing.md) — no db mocks
 """
 try await store.writeFile("MEMORY.md", content: original)

 let lossy = "- [Testing](feedback_testing.md) — no db mocks\n"
 do {
 try await store.writeFile("MEMORY.md", content: lossy)
 XCTFail("expected indexDroppedEntries throw")
 } catch MemoryStore.MemoryError.indexDroppedEntries(let missing) {
 XCTAssertEqual(missing, ["user_profile.md"])
 }
 }

 /// `MemoryStore.validated` accepts MEMORY.md and the four topic types
 /// (user, feedback, project, reference); rejects traversal, uppercase
 /// types, and unprefixed names.
 func test_memoryStore_pathValidation() async throws {
 let tempDir = makeTempDir
 defer { try? FileManager.default.removeItem(at: tempDir) }
 let store = MemoryStore(root: tempDir)

 for ok in ["MEMORY.md", "user_profile.md", "feedback_testing.md", "project_deadline.md", "reference_links.md"] {
 try await store.writeFile(ok, content: "---\nname: t\ndescription: t\ntype: user\n---\nbody\n")
 }

 for bad in ["../escape.md", "random.md", "FEEDBACK_X.md", "user_Profile.md", "user_.md"] {
 do {
 try await store.writeFile(bad, content: "x")
 XCTFail("expected path rejection for \(bad)")
 } catch MemoryStore.MemoryError.invalidPath(_) {
 // expected
 }
 }
 }

 // MARK: - AssistantSanitizer

 /// Channel-block stripping matches CC's Gemma-template markup list
 /// documented in `AssistantSanitizer.sanitize`.
 func test_assistantSanitizer_stripsChannelBlocks() {
 let raw = "Here is the answer: <|channel|>thought internal reasoning <channel|> actual response."
 let clean = AssistantSanitizer.sanitize(raw)
 XCTAssertFalse(clean.contains("<|channel|>"))
 XCTAssertFalse(clean.contains("<channel|>"))
 XCTAssertFalse(clean.contains("internal reasoning"))
 XCTAssertTrue(clean.contains("actual response"))
 }

 /// addition: sanitizer strips `<system-reminder>…</system-reminder>`
 /// so a model that parrots our meta injection doesn't leak it to the UI.
 func test_assistantSanitizer_stripsSystemReminderBlocks() {
 let raw = "Sure.<system-reminder>\nAnswer directly.\n</system-reminder> Here goes."
 let clean = AssistantSanitizer.sanitize(raw)
 XCTAssertFalse(clean.contains("<system-reminder>"))
 XCTAssertFalse(clean.contains("Answer directly"))
 XCTAssertTrue(clean.contains("Sure."))
 XCTAssertTrue(clean.contains("Here goes."))
 }

 /// Streaming sanitizer hides everything after an unclosed opener; the
 /// prefix before the opener is still emitted.
 func test_assistantSanitizer_streamingHidesOpenBlock() {
 let raw = "Visible prefix.<|channel|>thought hidden stuff never closed"
 let clean = AssistantSanitizer.sanitizeStreaming(raw)
 XCTAssertTrue(clean.contains("Visible prefix"))
 XCTAssertFalse(clean.contains("hidden stuff"))
 XCTAssertFalse(clean.contains("<|channel|>"))
 }

 ///  : the device log Turn 9 showed the model
 /// emitting `<system-reminder>...</system_prompt>` — an asymmetric
 /// closer. Without the alias closer `</system_prompt>` the streaming
 /// scanner stayed "hidden" after the opener and the bubble flickered
 /// with raw markup. Verify both aliases close the block properly.
 func test_assistantSanitizer_streamingClosesOnAsymmetricSystemPromptTag() {
 let raw = "Reply begin.<system-reminder>hidden payload</system_prompt> visible tail."
 let clean = AssistantSanitizer.sanitizeStreaming(raw)
 XCTAssertTrue(clean.contains("Reply begin"))
 XCTAssertFalse(clean.contains("hidden payload"))
 XCTAssertFalse(clean.contains("<system-reminder>"))
 XCTAssertFalse(clean.contains("</system_prompt>"))
 XCTAssertTrue(clean.contains("visible tail"))
 }

 func test_assistantSanitizer_streamingClosesOnBareSystemTag() {
 let raw = "Prefix.<system-reminder>secret</system> tail."
 let clean = AssistantSanitizer.sanitizeStreaming(raw)
 XCTAssertTrue(clean.contains("Prefix"))
 XCTAssertFalse(clean.contains("secret"))
 XCTAssertTrue(clean.contains("tail"))
 }

 /// Natural short follow-up questions should remain visible when they add
 /// conversational warmth instead of collapsing into a menu-like fallback.
 func test_assistantSanitizer_preservesNaturalFollowUpTail() {
 let raw = "I'm doing well. What would you like to work on today?"
 let clean = AssistantSanitizer.sanitize(raw)
 XCTAssertEqual(clean, raw)
 }

 func test_assistantSanitizer_preservesPersonalAssistantStyleFollowUp() {
 let raw = "Your name is Isaac. Want me to keep that in mind going forward?"
 let clean = AssistantSanitizer.sanitize(raw)
 XCTAssertEqual(clean, raw)
 }

 func test_assistantSanitizer_stripsStandaloneGenericHelpText() {
 let raw = "How can I help you today?"
 let clean = AssistantSanitizer.sanitize(raw)
 XCTAssertTrue(clean.isEmpty)
 }

 func test_assistantSanitizer_stripsGenericFollowUpMenuTail() {
 let raw = """
 Your name is Isaac.

 How can I help you next?
 1. Continue discussing the list above
 2. Ask a question about the list itself
 3. Start a new topic entirely
 """
 let clean = AssistantSanitizer.sanitize(raw)
 XCTAssertEqual(clean, "Your name is Isaac.")
 }

 /// Visible reasoning headers are presentation noise even when they are not
 /// wrapped in hidden-channel markup.
 func test_assistantSanitizer_stripsReasoningHeadingPrefix() {
 let raw = "Reasoning: The answer is 4."
 let clean = AssistantSanitizer.sanitize(raw)
 XCTAssertEqual(clean, "The answer is 4.")
 }

 // post-device-rerun fix: tail patterns now include the
 // "today" variants that Gemini emits naturally.
 func test_assistantSanitizer_stripsWhatCanIDoForYouTodayTail() {
 let clean = AssistantSanitizer.sanitize("Not much, just here to help! What can I do for you today?")
 XCTAssertEqual(clean, "Not much, just here to help!")
 }

 func test_assistantSanitizer_stripsHowCanIAssistYouTodayTail() {
 let clean = AssistantSanitizer.sanitize("Sure, I can explain that. How can I assist you today?")
 XCTAssertEqual(clean, "Sure, I can explain that.")
 }

 func test_assistantSanitizer_stripsStandaloneHowCanIAssistLine() {
 let clean = AssistantSanitizer.sanitize("The answer is 42.\nHow can I assist?")
 XCTAssertEqual(clean, "The answer is 42.")
 }

 // MARK: - MessageFactory

 /// `MessageFactory.wrapInSystemReminder` is idempotent — wrapping an
 /// already-wrapped string is a no-op. Mirrors CC's
 /// `ensureSystemReminderWrap` (`utils/messages.ts:1797-1817`).
 func test_messageFactory_wrapInSystemReminderIdempotent() {
 let once = MessageFactory.wrapInSystemReminder("hello")
 XCTAssertTrue(once.hasPrefix("<system-reminder>"))
 XCTAssertTrue(once.hasSuffix("</system-reminder>"))
 let twice = MessageFactory.wrapInSystemReminder(once)
 XCTAssertEqual(once, twice, "second wrap should be a no-op")
 }

 /// regression: the per-turn reminder should quote the latest
 /// user question so weak local models stay anchored to it instead of
 /// drifting into generic help text.
 func test_messagePipeline_reminderAnchorsLatestUserQuestion() {
 let pipeline = MessagePipeline
 let input: [RelayMessage] = [
 .user(UserContent(blocks: [.text("My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("Okay.") ])),
 .user(UserContent(blocks: [.text("What's my name?")]))
 ]

 let (messages, _) = pipeline.transform(input)
 guard case .user(let content) = messages.last else {
 return XCTFail("expected latest message to remain a user turn")
 }
 let joined = content.blocks.compactMap { block -> String? in
 if case .text(let text) = block { return text }
 return nil
 }.joined(separator: "\n")

 XCTAssertTrue(joined.contains("<system-reminder>"))
 XCTAssertTrue(joined.contains("Reply to: \"What's my name?\""))
 }

 // Prompt surgery deleted 3 obsolete tests here:
 // test_systemPrompt_treatsRuntimeTurnGuidanceAsAuthoritative
 // test_systemPrompt_addsNaturalConversationGuidanceForCasualOpeners
 // test_systemPrompt_forbidsReasoningHeadings
 // Their assertions locked the exact text of `answeringSection` /
 // `interactionStyleSection` / `outputEfficiencySection` rule bullets that
 // the surgery deleted. Behavior previously enforced by those bullets is
 // now carried by `exampleBankSection` few-shot examples, verified by the
 // existing `test_promptCompiler_selectsExampleBankForGemmaLocalClassifiedTurns`.

 /// regression: `ContextBuilder` should add a dynamic system
 /// section that explicitly frames the latest user message as primary and
 /// the recent visible tail as disambiguation-only context.
 func test_contextBuilder_addsConversationFocusSectionToSystemPrompt() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("Hi do you know who I am")])),
 .assistant(AssistantContent(blocks: [.text("I do not know who you are.")])),
 .user(UserContent(blocks: [.text("Can you remember my name? My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("Yes, I remember. Your name is Isaac.")])),
 .user(UserContent(blocks: [.text("What's my name?")])),
 ],
 turnCount: 3
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("# Current turn focus"))
 XCTAssertTrue(request.systemPrompt.contains("Turn classification: factRecallKnown"))
 XCTAssertTrue(request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertTrue(request.systemPrompt.contains("- Can you remember my name? My name is Isaac"))
 XCTAssertTrue(request.systemPrompt.contains("assistant: Yes, I remember. Your name is Isaac."))

 let overlay = builder.turnOverlayForTesting(from: state.messages)
 XCTAssertEqual(overlay?.classification, .factRecallKnown)
 XCTAssertEqual(overlay?.bindingPriority, .latestTurnWithVisibleFacts)
 XCTAssertEqual(overlay?.latestUserText, "What's my name?")
 XCTAssertEqual(overlay?.visibleFacts.map(\.text), ["Can you remember my name? My name is Isaac"])
 XCTAssertEqual(overlay?.recentTail, [
 BoundConversationTurn(role: "assistant", text: "Yes, I remember. Your name is Isaac.")
 ])
 XCTAssertTrue((overlay?.retrievalArtifacts ?? []).isEmpty)
 XCTAssertNil(overlay?.summarySnippet)
 XCTAssertEqual(
 overlay?.instructions,
 [
 "Treat the latest user message as the primary query for this turn.",
 "Answer by restating the visible fact directly in one sentence.",
 "Do not ask the user to repeat the fact, and do not answer with uncertainty."
 ]
 )
 }

 /// Unrelated previous turns should not be copied into the focus section,
 /// or weak local models may answer the older question instead of the
 /// latest one.
 func test_contextBuilder_omitsUnrelatedRecentTail() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("Can you hear me?")])),
 .assistant(AssistantContent(blocks: [.text("I am ready. What can I do for you?")])),
 .user(UserContent(blocks: [.text("What's my name?")])),
 ],
 turnCount: 2
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("# Current turn focus"))
 XCTAssertTrue(request.systemPrompt.contains("Turn classification: factRecallUnknown"))
 XCTAssertFalse(request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertFalse(request.systemPrompt.contains("Relevant recent conversation:"))
 XCTAssertFalse(request.systemPrompt.contains("user: Can you hear me?"))
 XCTAssertFalse(request.systemPrompt.contains("assistant: I am ready. What can I do for you?"))
 }

 /// Fact-recall turns should not drag in unrelated assistant chatter that
 /// happened after the relevant declarative fact, or the latest recall
 /// question can lose dominance.
 func test_contextBuilder_factRecall_excludesUnrelatedAssistantChatterBetweenFactAndRecall() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("The weather in Boston is rainy today.")])),
 .user(UserContent(blocks: [.text("What's my name?")])),
 ],
 turnCount: 2
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: factRecallKnown"))
 XCTAssertTrue(request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertTrue(request.systemPrompt.contains("- My name is Isaac"))
 XCTAssertFalse(request.systemPrompt.contains("weather in Boston"))
 }

 func test_contextBuilder_referentialFollowup_includesImmediateAnswerContextWithoutLexicalOverlap() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("What is this about?")])),
 .assistant(AssistantContent(blocks: [.text("It is a plan to refactor nine parts of the system architecture.")])),
 .user(UserContent(blocks: [.text("Explain more clearly")])),
 ],
 turnCount: 2
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: referentialFollowup"))
 XCTAssertTrue(request.systemPrompt.contains("user: What is this about?"))
 XCTAssertTrue(request.systemPrompt.contains("assistant: It is a plan to refactor nine parts of the system architecture."))
 }

 func test_contextBuilder_factRecall_survivesUnrelatedSummaryDetour() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("My name is Isaac")])),
 .assistant(AssistantContent(blocks: [.text("I remember that your name is Isaac.")])),
 .user(UserContent(blocks: [.text("Summarize this architecture list")])),
 .assistant(AssistantContent(blocks: [.text("It is a plan to refactor nine parts of the system.")])),
 .user(UserContent(blocks: [.text("Explain more clearly")])),
 .assistant(AssistantContent(blocks: [.text("The list is a refactor roadmap across nine system areas.")])),
 .user(UserContent(blocks: [.text("What is my name?")])),
 ],
 turnCount: 4
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: factRecallKnown"))
 XCTAssertTrue(request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertTrue(request.systemPrompt.contains("- My name is Isaac"))
 XCTAssertFalse(request.systemPrompt.contains("refactor roadmap"))
 XCTAssertFalse(request.systemPrompt.contains("nine parts of the system"))
 }

 func test_contextBuilder_factRecall_withoutVisibleFact_explicitlySaysUnknownFactPath() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("Hi")])),
 .assistant(AssistantContent(blocks: [.text("Hey. I'm doing well. What would you like to work on today?")])),
 .user(UserContent(blocks: [.text("What is your name?")])),
 .assistant(AssistantContent(blocks: [.text("I am Glass.")])),
 .user(UserContent(blocks: [.text("What is my name?")])),
 ],
 turnCount: 3
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: factRecallUnknown"))
 XCTAssertTrue(request.systemPrompt.contains("Latest visible facts:\n- none available for this turn"))
 XCTAssertTrue(request.systemPrompt.contains("No visible fact currently answers this recall question. Say you do not know it yet and invite the user to tell you."))
 XCTAssertTrue(request.systemPrompt.contains("Do not reply with generic next-step boilerplate like \"How can I help you today?\" or \"Please tell me what you would like to do next.\""))

 let overlay = builder.turnOverlayForTesting(from: state.messages)
 XCTAssertEqual(overlay?.classification, .factRecallUnknown)
 XCTAssertEqual(overlay?.bindingPriority, .latestTurnOnly)
 XCTAssertEqual(overlay?.latestUserText, "What is my name?")
 XCTAssertEqual(overlay?.visibleFacts, [])
 XCTAssertEqual(overlay?.recentTail, [])
 XCTAssertTrue((overlay?.retrievalArtifacts ?? []).isEmpty)
 XCTAssertNil(overlay?.summarySnippet)
 XCTAssertEqual(
 overlay?.instructions,
 [
 "Treat the latest user message as the primary query for this turn.",
 "No visible fact currently answers this recall question. Say you do not know it yet and invite the user to tell you. Do not switch to generic help text.",
 "Do not reply with generic next-step boilerplate like \"How can I help you today?\" or \"Please tell me what you would like to do next.\""
 ]
 )
 }

 func test_contextBuilder_socialOpener_focus_blocksGenericFallback() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("Hi, how are you?")])),
 ],
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

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: socialOpener"))
 XCTAssertTrue(request.systemPrompt.contains("A warmer two-to-four sentence reply is appropriate here, and one light follow-up is allowed."))
 XCTAssertTrue(request.systemPrompt.contains("Do not call the message open-ended, do not ask for more context, and do not fall back to attachment or image prompts."))

 let overlay = builder.turnOverlayForTesting(from: state.messages)
 XCTAssertEqual(overlay?.classification, .socialOpener)
 XCTAssertEqual(
 overlay?.instructions,
 [
 "Treat the latest user message as the primary query for this turn.",
 "A warmer two-to-four sentence reply is appropriate here, and one light follow-up is allowed.",
 "Do not call the message open-ended, do not ask for more context, and do not fall back to attachment or image prompts."
 ]
 )
 }

 func test_contextBuilder_assistantIdentityQuestion_directsGlassName() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("What is your name?")])),
 ],
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

 XCTAssertTrue(request.systemPrompt.contains("The user is asking for your assistant name or how to address you. Answer \"Glass.\""))
 XCTAssertTrue(request.systemPrompt.contains("Do not answer with the model or provider name like \"Gemma 4\" or \"Gemini\"."))

 let overlay = builder.turnOverlayForTesting(from: state.messages)
 XCTAssertEqual(overlay?.classification, .question)
 XCTAssertEqual(
 overlay?.instructions,
 [
 "Treat the latest user message as the primary query for this turn.",
 "The user is asking for your assistant name or how to address you. Answer \"Glass.\" Do not answer with the model or provider name like \"Gemma 4\" or \"Gemini\"."
 ]
 )
 }

 /// Short repair cues like "Tf" still need the immediately previous missed
 /// turn in focus context, even though there is no lexical overlap.
 func test_contextBuilder_includesRepairContextForShortReaction() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("Hi, who am I?")])),
 .assistant(AssistantContent(blocks: [.text("I do not have information about who you are.")])),
 .user(UserContent(blocks: [.text("My name is Isaac just fyi")])),
 .assistant(AssistantContent(blocks: [.text("Please provide the text or image, question, or request you would like me to help you with!")])),
 .user(UserContent(blocks: [.text("Tf")])),
 ],
 turnCount: 3
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: repairCue"))
 XCTAssertTrue(request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertTrue(request.systemPrompt.contains("- My name is Isaac just fyi"))
 XCTAssertTrue(request.systemPrompt.contains("user: My name is Isaac just fyi"))
 XCTAssertTrue(request.systemPrompt.contains("assistant: Please provide the text or image"))
 }

 /// Repeated repair / complaint turns should still pull in the earlier
 /// substantive user fact instead of collapsing to only the last short cue.
 func test_contextBuilder_repeatedRepairTurnKeepsSubstantiveFactVisible() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("Hi, who am I?")])),
 .assistant(AssistantContent(blocks: [.text("I do not have information about who you are.")])),
 .user(UserContent(blocks: [.text("My name is Isaac just fyi")])),
 .assistant(AssistantContent(blocks: [.text("Please provide the text or image, question, or request you would like me to help you with!")])),
 .user(UserContent(blocks: [.text("Tf")])),
 .assistant(AssistantContent(blocks: [.text("I have saved your name as Isaac.")])),
 .user(UserContent(blocks: [.text("ARE U LISTENING ME")])),
 ],
 turnCount: 4
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: repairCue"))
 XCTAssertTrue(request.systemPrompt.contains("user: My name is Isaac just fyi"))
 XCTAssertTrue(request.systemPrompt.contains("assistant: I have saved your name as Isaac."))
 XCTAssertTrue(request.systemPrompt.contains("Latest visible facts:"))
 XCTAssertTrue(request.systemPrompt.contains("- My name is Isaac just fyi"))
 }

 func test_contextBuilder_transportCheckOmitsTailAndUsesTransportDirective() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .assistant(AssistantContent(blocks: [.text("I am ready whenever you are.")])),
 .user(UserContent(blocks: [.text("Can you hear me?")])),
 ],
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

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: transportCheck"))
 XCTAssertFalse(request.systemPrompt.contains("Relevant recent conversation:"))
 XCTAssertFalse(request.systemPrompt.contains("Compacted history summary:"))
 }

 func test_contextBuilder_toolFollowupIncludesImmediateRecentContext() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .assistant(AssistantContent(blocks: [.text("I drafted the message and can send it now.")])),
 .user(UserContent(blocks: [.text("go ahead")])),
 ],
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

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: toolFollowup"))
 XCTAssertTrue(request.systemPrompt.contains("assistant: I drafted the message and can send it now."))
 }

 func test_contextBuilder_broadQuestionCanUseCompactedSummaryWithoutOverridingLatestTurn() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [.text("What are we working on right now?")])),
 ],
 turnCount: 5,
 summaryState: SessionSummaryState(
 latestBoundarySummary: "We are building Glass as an iPhone-native agent runtime with recent work focused on retrieval and binding.",
 lastCompactedAtTurnCount: 4,
 latestBoundaryMessageIndex: 0
 )
 )

 let request = await builder.build(
 state: state,
 enabledToolNames: [],
 environment: .current,
 extraSystemContext: [:],
 tools: [],
 options: .init()
 )

 XCTAssertTrue(request.systemPrompt.contains("Turn classification: question"))
 XCTAssertTrue(request.systemPrompt.contains("Compacted history summary:"))
 XCTAssertTrue(request.systemPrompt.contains("We are building Glass as an iPhone-native agent runtime"))
 }

 func test_contextBuilder_fileTurnFocusUsesVisibleUserTextNotSyntheticPreamble() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [
 .text("Summarize this."),
 .fileRef(ImportedFileRef(
 attachmentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222") ?? UUID(),
 displayName: "Guide.md",
 contentTypeIdentifier: "public.plain-text"
 )),
 ])),
 ],
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

 XCTAssertFalse(request.systemPrompt.contains("Latest user message:\nAttached files:"))

 guard case .user(let content) = request.messages.last else {
 return XCTFail("expected projected user message")
 }
 guard case .text(let modelText) = content.blocks.first else {
 return XCTFail("expected projected text block")
 }
 XCTAssertTrue(modelText.contains("Attached files: Guide.md."))
 XCTAssertTrue(modelText.contains("Summarize this."))
 }

 func test_contextBuilder_projectsPersistedFileOnlyTurnBackIntoModelMessages() async {
 let builder = ContextBuilder(memoryStore: nil)
 let state = AgentSessionState(
 messages: [
 .user(UserContent(blocks: [
 .fileRef(ImportedFileRef(
 attachmentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-333333333333") ?? UUID(),
 displayName: "Notes.txt",
 contentTypeIdentifier: "public.plain-text"
 )),
 ])),
 ],
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

 XCTAssertFalse(request.systemPrompt.contains("Latest user message:\nUser attached file"))
 guard case .user(let content) = request.messages.last else {
 return XCTFail("expected projected user message")
 }
 XCTAssertEqual(content.blocks.count, 1)
 guard case .text(let modelText) = content.blocks[0] else {
 return XCTFail("expected acknowledgement preamble")
 }
 XCTAssertTrue(modelText.contains("User attached file(s): Notes.txt."))
 XCTAssertTrue(modelText.contains("ask what they want analyzed"))
 }

 /// Generic context-artifact wrappers should remain structurally
 /// unambiguous even when the payload contains quotes or a fake closing tag.
 func test_messageFactory_contextArtifact_escapesTagSensitivePayload() {
 let message = MessageFactory.contextArtifact(
 ContextArtifact(
 id: "artifact-1",
 kind: .attachment,
 sourceDisplayName: #"manual "A""#,
 text: #"quote "x" and </context-artifact> tag"#,
 tokenEstimate: 12,
 position: 1,
 totalParts: 2
 )
 )
 guard case .user(let content) = message,
 case .text(let wrapped)? = content.blocks.first else {
 return XCTFail("expected text-wrapped meta user message")
 }

 XCTAssertEqual(wrapped.components(separatedBy: "</context-artifact>").count - 1, 1)
 XCTAssertTrue(wrapped.contains(#"\u003C/context-artifact\u003E"#))
 XCTAssertTrue(wrapped.contains(#"manual \"A\""#))
 }

 /// Gemini key resolution should respect the persisted Keychain value first.
 func test_relayConfig_resolvedGeminiKey_prefersStoredValue() {
 var persisted: [String] = []
 let resolved = RelayConfig.resolvedGeminiKey(
 storedKey: "stored-key",
 bundledKey: "bundled-key",
 envKey: "env-key",
 persist: { persisted.append($0) }
 )

 XCTAssertEqual(resolved, "stored-key")
 XCTAssertTrue(persisted.isEmpty)
 }

 /// Device builds need a non-repo local secret path. If a bundled developer
 /// plist is present, it should seed Keychain and become the active value.
 func test_relayConfig_resolvedGeminiKey_usesBundledFallbackAndPersists() {
 var persisted: [String] = []
 let resolved = RelayConfig.resolvedGeminiKey(
 storedKey: nil,
 bundledKey: "bundled-key",
 envKey: "env-key",
 persist: { persisted.append($0) }
 )

 XCTAssertEqual(resolved, "bundled-key")
 XCTAssertEqual(persisted, ["bundled-key"])
 }

 /// Reload should no longer clear an env-only key path just because
 /// Keychain is currently empty.
 func test_relayConfig_resolvedGeminiKey_usesEnvFallbackAndPersists() {
 var persisted: [String] = []
 let resolved = RelayConfig.resolvedGeminiKey(
 storedKey: nil,
 bundledKey: nil,
 envKey: " env-key ",
 persist: { persisted.append($0) }
 )

 XCTAssertEqual(resolved, "env-key")
 XCTAssertEqual(persisted, ["env-key"])
 }

 /// Low-temperature defaults reduce local Gemma drift on short factual
 /// follow-up turns while still allowing some variation.
 func test_completionOptions_defaultTemperature_isLow() {
 let options = CactusModelHost.CompletionOptions
 XCTAssertEqual(options.temperature ?? -1, 0.2, accuracy: 0.0001)
 }

 // MARK: - Codable back-compat

 /// Persisted transcripts from before don't carry `isMeta`; they
 /// must still decode cleanly with `isMeta == false`.
 func test_userContent_isMetaDecodableBackCompat() throws {
 let jsonWithout = #"""
 {"blocks":[{"text":"hello"}]}
 """#.data(using: .utf8)!
 let content = try JSONDecoder.decode(UserContent.self, from: jsonWithout)
 XCTAssertFalse(content.isMeta)
 }

 // MARK: - Hydrate repair

 /// addition: `AgentCore.hydrate` runs the same tool-pair
 /// repair as `runTurn`. A session killed mid-dispatch leaves an orphan
 /// `tool_use`; on resume, hydrate synthesizes the missing result so the
 /// display no longer shows a dangling tool card.
 func test_hydrate_repairsOrphanToolUseFromPreviousSession() async {
 // Minimal CactusModelHost init — we only need the actor shell, no model.
 let host = CactusModelHost(modelPath: "/dev/null")
 let core = AgentCore(host: host)

 let orphan = ToolUseBlock(id: "call_resumed", name: "x", inputJson: "{}")
 let persisted: [RelayMessage] = [
 .user(UserContent(blocks: [.text("hi")])),
 .assistant(AssistantContent(blocks: [.toolUse(orphan)])),
 ]
 await core.hydrate(history: persisted)
 let count = await core.messageCount
 XCTAssertEqual(count, 3, "hydrate should inject a synthetic tool_result for the orphan")
 }

 // MARK: - GlobTool pattern compilation

 /// Sanity test for the glob→regex translator. `**/*.swift` should match
 /// `Relay/Agent/AgentCore.swift` and NOT `README.md`.
 func test_globTool_globToRegex_matchesNestedSwift() throws {
 let pattern = GlobTool.globToRegex("**/*.swift")
 let regex = try NSRegularExpression(pattern: pattern)

 func matches(_ s: String) -> Bool {
 let ns = s as NSString
 return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
 }
 XCTAssertTrue(matches("Relay/Agent/AgentCore.swift"))
 XCTAssertTrue(matches("AgentCore.swift"))
 XCTAssertFalse(matches("README.md"))
 XCTAssertFalse(matches("Relay/Agent/AgentCore.swift.bak"))
 }

 // MARK: - Helpers

 private func makeTempDir() -> URL {
 let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
 "RelayHarnessTests-\(UUID().uuidString)",
 isDirectory: true
 )
 try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 return dir
 }
}
