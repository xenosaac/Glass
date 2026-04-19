import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Composable, section-based system-prompt assembly for Relay.
///
/// into Swift. Sections are returned as a `[String]` so the future cache
/// layer can memoize static sections independently; today `AgentCore`
/// joins them with `"\n\n"` before handing to the host.
///
/// Text marked "verbatim" below is copied unchanged from the reference agent —
/// those instructions are battle-tested. Text marked "custom" is tailored
/// for Gemma-4-E2B's weaker instruction-following (no greetings,
/// topic-switch discipline, text-only default).
public enum SystemPrompt {

 // MARK: - Environment

 public struct Environment: Sendable, Equatable {
 public let model: String
 public let platform: String
 public let currentDate: String

 public init(model: String, platform: String, currentDate: String) {
 self.model = model
 self.platform = platform
 self.currentDate = currentDate
 }

 /// Snapshot of the current runtime.
 public static var current: Environment {
 let fmt = DateFormatter()
 fmt.dateFormat = "yyyy-MM-dd"
 fmt.locale = Locale(identifier: "en_US_POSIX")
 let date = fmt.string(from: Date())

 let platform: String
 #if canImport(UIKit)
 let sys = UIDevice.current.systemName
 let ver = UIDevice.current.systemVersion
 platform = "\(sys) \(ver)"
 #else
 platform = "iOS"
 #endif

 return Environment(
 model: "gemma-4-e2b-it",
 platform: platform,
 currentDate: date
 )
 }
 }

 // MARK: - Boundary

 /// Marker separating static (cacheable) content from dynamic content.
 /// No-op today — Relay has no server cache — but kept for semantic
 /// clarity and future caching. Ports
 /// `SYSTEM_PROMPT_DYNAMIC_BOUNDARY` (`constants/prompts.ts:114-115`).
 public static let dynamicBoundary = "__SYSTEM_PROMPT_DYNAMIC_BOUNDARY__"

 // MARK: - Build

 /// Build the full prompt as an array of section strings.
 /// Ports `getSystemPrompt` (`constants/prompts.ts:444-577`).
 public static func build(
 enabledToolNames: Set<String> = [],
 toolDescriptions: [String: String] = [:],
 environment: Environment,
 memoryIndex: String? = nil,
 memoryTopics: [String: String] = [:]
 ) -> [String] {
 basePromptSections(
 enabledToolNames: enabledToolNames,
 toolDescriptions: toolDescriptions,
 environment: environment,
 memoryIndex: memoryIndex,
 memoryTopics: memoryTopics
 )
 .map(\.text)
 }

 /// Append "key: value" pairs as a single trailing block. Ports
 /// `appendSystemContext` (`utils/api.ts:437-447`).
 public static func appendSystemContext(
 _ sections: [String],
 _ context: [String: String]
 ) -> [String] {
 guard !context.isEmpty else { return sections }
 let line = context
 .sorted() { $0.key < $1.key }
 .map { "\($0.key): \($0.value)" }
 .joined(separator: "\n")
 return sections + [line]
 }

 // MARK: - Module 01 prompt compiler sources

 internal static func basePromptSections(
 enabledToolNames: Set<String>,
 toolDescriptions: [String: String] = [:],
 environment: Environment,
 memoryIndex: String?,
 memoryTopics: [String: String],
 profileID: PromptProfileID = .gemmaLocal
 ) -> [PromptSection] {
 let allProfiles = Set(PromptProfileID.allCases)
 // Prompt surgery : dropped interactionStyle / toneAndStyle /
 // outputEfficiency sections. Their abstract tone / conciseness rules are
 // not enforceable on a 2B CPU model; exampleBank few-shot now carries
 // those patterns. Language-match rule was absorbed into answeringSection.
 var sections: [PromptSection] = [
 PromptSection(id: .intro, layer: .stableBootstrap, owner: .systemPrompt, required: true, truncationPriority: 0, profileApplicability: allProfiles, text: introSection()),
 PromptSection(id: .systemRules, layer: .stableBootstrap, owner: .systemPrompt, required: true, truncationPriority: 0, profileApplicability: allProfiles, text: systemSection()),
 PromptSection(id: .answering, layer: .stableBootstrap, owner: .systemPrompt, required: true, truncationPriority: 0, profileApplicability: allProfiles, text: answeringSection()),
 PromptSection(id: .multimodal, layer: .stableBootstrap, owner: .systemPrompt, required: true, truncationPriority: 10, profileApplicability: allProfiles, text: multimodalSection()),
 ]

 if !enabledToolNames.isEmpty {
 sections.append(
 PromptSection(
 id: .availableTools,
 layer: .stableBootstrap,
 owner: .systemPrompt,
 required: false,
 truncationPriority: 20,
 profileApplicability: allProfiles,
 text: toolsSection(enabledToolNames, descriptions: toolDescriptions)
 )
 )
 // 1 Tool selection
 // guidance. Inserted AFTER the available-tools list (so the
 // model can map names to rules) and BEFORE the dynamic
 // boundary (so it stays in the cacheable stable prefix).
 // Activates the existing `PromptSectionID.toolGovernance`
 // case — defined but previously unused. Primary purpose:
 // counter the destructive salience the Memory section had
 // for `memory_write` selection under `toolConfig.mode=ANY`,
 // which was the root cause of `What time is it?` getting
 // hijacked into a memory_write call before R6-Mem hotfix #4.
 sections.append(
 PromptSection(
 id: .toolGovernance,
 layer: .stableBootstrap,
 owner: .systemPrompt,
 required: false,
 truncationPriority: 25,
 profileApplicability: allProfiles,
 text: toolGovernanceSection(enabledToolNames: enabledToolNames)
 )
 )
 }

 sections.append(
 PromptSection(
 id: .dynamicBoundary,
 layer: .stableBootstrap,
 owner: .promptCompiler,
 required: true,
 truncationPriority: 0,
 profileApplicability: allProfiles,
 text: dynamicBoundary
 )
 )

 if let memoryIndex {
 sections.append(
 PromptSection(
 id: .memory,
 layer: .stableBootstrap,
 owner: .systemPrompt,
 required: false,
 truncationPriority: 30,
 profileApplicability: allProfiles,
 text: memorySection(index: memoryIndex, topics: memoryTopics)
 )
 )
 }

 sections.append(
 PromptSection(
 id: .environment,
 layer: .stableBootstrap,
 owner: .systemPrompt,
 required: true,
 truncationPriority: 10,
 profileApplicability: allProfiles,
 text: environmentSection(environment)
 )
 )

 return sections
 }

 internal static func extraSystemContextSection(
 _ context: [String: String],
 profileID: PromptProfileID = .gemmaLocal
 ) -> PromptSection? {
 guard let rendered = appendSystemContext([], context).first else { return nil }
 let allProfiles = Set(PromptProfileID.allCases)
 return PromptSection(
 id: .extraSystemContext,
 layer: .stableBootstrap,
 owner: .promptCompiler,
 required: false,
 truncationPriority: 40,
 profileApplicability: allProfiles,
 text: rendered
 )
 }

 internal static func currentTurnFocusSection(
 _ currentTurnFocus: String?,
 profileID: PromptProfileID = .gemmaLocal
 ) -> PromptSection? {
 guard let currentTurnFocus,
 !currentTurnFocus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
 return nil
 }
 let allProfiles = Set(PromptProfileID.allCases)
 return PromptSection(
 id: .currentTurnFocus,
 layer: .dynamicTurn,
 owner: .contextBuilder,
 required: false,
 truncationPriority: 0,
 profileApplicability: allProfiles,
 text: currentTurnFocus
 )
 }

 internal static func recoveryNotesSection(
 _ recoveryNotes: String?,
 profileID: PromptProfileID = .gemmaLocal
 ) -> PromptSection? {
 guard let recoveryNotes,
 !recoveryNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
 return nil
 }
 let allProfiles = Set(PromptProfileID.allCases)
 return PromptSection(
 id: .recoveryNotes,
 layer: .recoveryRuntime,
 owner: .runtimeRecovery,
 required: false,
 truncationPriority: 0,
 profileApplicability: allProfiles,
 text: recoveryNotes
 )
 }

 internal static func exampleBankSection(
 _ moduleIDs: [PromptExampleModuleID],
 profileID: PromptProfileID = .gemmaLocal
 ) -> PromptSection? {
 guard profileID == .gemmaLocal, !moduleIDs.isEmpty else { return nil }
 return PromptSection(
 id: .exampleBank,
 layer: .exampleBank,
 owner: .promptCompiler,
 required: false,
 truncationPriority: 50,
 profileApplicability: [.gemmaLocal],
 text: exampleBankText(for: moduleIDs)
 )
 }

 // MARK: - Sections (private)

 private static func introSection() -> String {
 // Custom — Glass identity.
 return """
 You are Glass, an on-device AI assistant running locally on the user's iPhone via the Gemma-4 model. You help the user with questions, tasks, and using their device.
 """
 }

 private static func systemSection() -> String {
 // Prompt surgery: 4 bullets -> 2. Removed the long <system-reminder>
 // explanation (now that MessagePipeline emits a single terse anchor
 // line, the heavyweight explanation is over-specification) and the
 // tool-denial-do-not-retry rule (restated where tools are discussed if
 // needed).
 return """
 # System
 - All text you output outside of tool use is displayed to the user. You can use Github-flavored markdown for formatting.
 - Tool results and user messages may include <system-reminder> tags with runtime guidance. Follow them; do not quote them back.
 """
 }

 private static func answeringSection() -> String {
 // Prompt surgery: 13 bullets -> 3, then post-device-rerun
 // fix added the identity bullet back (narrow deterministic answer;
 // exampleBank has no identity module today; device rerun showed Gemma
 // drifting to off-topic help-desk text on "What is your name?" with
 // `.question` classification). Net 4 bullets, ~20 tokens over the
 // 3-bullet surgery baseline. Budget test still has ~200 tokens
 // of headroom under the 600-token cold-start assertion.
 return """
 # Answering
 - Answer the user's current message directly. Do not restart with a greeting or generic offer to help.
 - If the user asks for your name or how to address you, answer "Glass." in one sentence — do not answer with "Gemma", "Gemini", or any underlying model or provider name.
 - If the user's request maps to an available tool, call it. Do not ask the user to do it themselves.
 - If you don't know something and no available tool can find it, say "I don't have information about [topic]." in one sentence. Do not invent facts.
 - Match the user's language (English or Chinese). Technical terms stay in their original form.
 """
 }

 private static func multimodalSection() -> String {
 // Custom — Gemma-4 is multimodal and tends to hallucinate missing
 // images on text-only turns.
 return """
 # Multimodal
 - This assistant supports text, audio, and images. Only reference images, audio, or attachments when the user has actually attached one in the current turn. Never ask "please provide the image" on a text-only message.
 """
 }

 // Prompt surgery deleted `interactionStyleSection`,
 // `toneSection`, and `outputEfficiencySection`. Their bullets were
 // abstract tone / conciseness rules that a 2B CPU model cannot reliably
 // follow; exampleBank few-shot now carries those patterns demonstratively.
 // The one load-bearing rule among them (language matching) was absorbed
 // into `answeringSection`.

 private static func exampleBankText(for moduleIDs: [PromptExampleModuleID]) -> String {
 let examples = moduleIDs.map(exampleText(for:))
 return """
 # Current-turn examples
 Match the response pattern shown below for this turn.

 \(examples.joined(separator: "\n\n"))
 """
 }

 private static func exampleText(for moduleID: PromptExampleModuleID) -> String {
 switch moduleID {
 case .socialGreeting:
 return """
 Example: social greeting
 User: "Hi"
 Assistant: "Hey. I'm doing well. What would you like to work on today?"
 """
 case .socialCheckIn:
 return """
 Example: social check-in
 User: "How are you?"
 Assistant: "I'm doing well, thanks. What's on your mind?"
 """
 case .factRecallKnown:
 return """
 Example: fact recall with known answer
 User: "My name is Isaac."
 Assistant: "Got it. I'll remember that."
 User: "What is my name?"
 Assistant: "Your name is Isaac."
 """
 case .factRecallUnknown:
 return """
 Example: fact recall with no known answer
 User: "What is my name?"
 Assistant: "I don't know your name yet. Tell me and I'll remember it."
 """
 case .referentialFollowup:
 return """
 Example: referential follow-up
 Assistant: "It is a roadmap for refactoring the app into clearer subsystems."
 User: "Explain more clearly."
 Assistant: "It is a plan to separate responsibilities so the app is easier to reason about and maintain."
 """
 case .repairCue:
 return """
 Example: repair cue
 User: "That's not what I asked."
 Assistant: correct the immediately previous answer directly.
 """
 case .retrievalFollowup:
 return """
 Example: retrieval follow-up
 User: "What does the attachment say about launch timing?"
 Assistant: answer using the retrieved attachment context, focused on launch timing.
 """
 case .toolContinuation:
 return """
 Example: tool continuation
 User: "Now summarize the result."
 Assistant: continue directly from the previous tool result instead of restarting.
 """
 case .identityQuestion:
 // identity questions have a hard
 // text rule in `answeringSection` but at long context Gemma
 // drops it and replies "I am Gemma 4...". A demonstrative
 // example is more salient than a single rule bullet for a 2B
 // CPU model.
 return """
 Example: identity question
 User: "Tell me about yourself."
 Assistant: "I'm Glass, an on-device assistant on your iPhone. Ask me anything and I'll help."
 User: "Who are you?"
 Assistant: "Glass."
 """
 }
 }

 /// 1 anti-bias tool-selection
 /// rules. Emits one bullet per enabled tool name we have an
 /// opinion about; skips bullets for tools that aren't enabled to
 /// keep the section budget tight (~60-120 tokens depending on
 /// configuration).
 ///
 /// Counters the prompt-salience problem the audit surfaced: under
 /// `toolConfig.mode=ANY`, the model picks the most-emphasized tool
 /// in the prompt. Memory's instruction block (even after the A.1
 /// trim) is still a sizable section; without explicit "don't use
 /// memory_write for unrelated queries" guidance, the model
 /// continues to over-pick it.
 private static func toolGovernanceSection(enabledToolNames: Set<String>) -> String {
 // trimmed to CONSTRAINT-ONLY rules after
 // Intervention 2 moved per-tool selection cues into
 // `toolsSection` via per-tool descriptions. Rules kept here are
 // ones that can't be expressed from a tool description alone:
 // "memory_write is for X ONLY" — a NEGATIVE constraint on when
 // NOT to call a tool, needed because otherwise Gemma over-picks
 // it whenever it sees any personal fact.
 // "Web search is pre-routed" — user-visible control-flow fact
 // (search is handled by a pre-route, not a tool call).
 // Do not add "use X for Y" rules here; put them in tool
 // descriptions instead so every tool gets its cue the same way.
 var lines: [String] = ["# Tool selection", ""]
 if enabledToolNames.contains("memory_write") {
 lines.append(" - `memory_write` is for explicit save requests ONLY (\"remember that...\"). Do NOT call it for time queries, schedule queries, or general questions. Default to no memory write unless the user asked to save something.")
 }
 lines.append(" - Web search and conversation summarization are pre-routed automatically — do not invoke a tool for them.")
 return lines.joined(separator: "\n")
 }

 /// render tools with per-tool first-sentence
 /// descriptions when available, falling back to name-only for tools
 /// missing from the catalog. Mirrors CC's `getUsingYourToolsSection`
 /// pattern (`constants/prompts.ts:269-314`) of giving the model
 /// explicit selection cues in the prompt rather than leaving tool
 /// choice to name-salience alone.
 private static func toolsSection(
 _ names: Set<String>,
 descriptions: [String: String] = [:]
 ) -> String {
 let sorted = names.sorted()
 let bullets = sorted.map { name -> String in
 guard let raw = descriptions[name], !raw.isEmpty else {
 return " - \(name)"
 }
 // robust first-sentence extraction.
 // The original `split(separator: ".")` was naive about three
 // real cases in our tool descriptions:
 // (1) multi-line bullet descriptions (Glob/Grep/Read)
 // leaked their `\n- ` bullets into the prompt,
 // (2) tool authors' own leading "- " prefix (GlobTool's
 // description literally starts with "- Fast file ...")
 // slipped through and appeared as a stray bullet,
 // (3) periods inside strings like "**/*.tsx" split the
 // sentence mid-word.
 // Pipeline: collapse newlines → strip leading bullet → split
 // on ". " (period + space) as the real sentence boundary →
 // collapse whitespace runs → cap at 120 chars with ellipsis.
 let collapsed = raw
 .replacingOccurrences(of: "\n", with: " ")
 .replacingOccurrences(of: "\r", with: " ")
 var normalized = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
 while normalized.hasPrefix("- ") { normalized.removeFirst(2) }
 let firstSentence: String
 if let range = normalized.range(of: ". ") {
 firstSentence = String(normalized[..<range.lowerBound])
 } else if normalized.hasSuffix(".") {
 firstSentence = String(normalized.dropLast)
 } else {
 firstSentence = normalized
 }
 let cleaned = firstSentence
 .components(separatedBy: .whitespacesAndNewlines)
 .filter { !$0.isEmpty }
 .joined(separator: " ")
 let trimmed = cleaned.count > 120
 ? String(cleaned.prefix(120)) + "…"
 : cleaned
 return " - \(name): \(trimmed)."
 }.joined(separator: "\n")
 return """
 # Available tools
 You have the following tools available:
 \(bullets)
 Only call tools by these exact names. Prefer the most specific tool for the task.
 You can call multiple tools in a single response. If you intend to call multiple tools and there are no dependencies between them, make all independent tool calls in parallel.
 """
 }

 /// Memory section. Static instructions adapted from the reference agent's
 /// `memdir/memdir.ts:199-316`, then the current `MEMORY.md` index
 /// verbatim (or "(empty)" on cold start), then every topic file's body
 /// inlined so the model can reason over memory without a separate read
 /// tool.
 ///
 /// topic bodies are NOW rendered. Prior
 /// code did `_ = topics` and dropped every body — model could see the
 /// `MEMORY.md` index but not the underlying facts, so even a perfectly-
 /// written `user_name.md` was invisible at recall time. Topics are
 /// rendered alphabetically by displayName under a `## Topic file
 /// contents` subsection so prompt caching stays stable across runs.
 private static func memorySection(index: String, topics: [String: String]) -> String {
 let body = index.trimmingCharacters(in: .whitespacesAndNewlines)
 let topicsBlock = renderTopicsBlock(topics)

 // Prompt surgery: when MEMORY.md is empty (typical cold-start case), the
 // 470-token "how to save / types / when to save / do-not-save" block is
 // pure bloat the model cannot act on without any existing memory. Swap
 // in a ~30-token pointer; the full instruction block kicks back in as
 // soon as the user has real memory content to reason over.
 //
 // note: Layer 2 cold-start stub (single italicized line) keeps
 // `body` non-empty at first launch, so the full block fires from turn 1.
 // The minimal-stub branch below is only reached when the index is
 // explicitly emptied (e.g. user calls Clear All in Settings) AND no
 // topics survive the wipe.
 if body.isEmpty {
 let base = """
 # Memory
 You have persistent, on-device memory. When the user asks you to remember something, call the `memory_write` tool. When they ask you to forget, overwrite the file.
 """
 return topicsBlock.isEmpty ? base : "\(base)\n\n\(topicsBlock)"
 }
 let displayedIndex = body
 // 1 trimmed from ~470 → ~150
 // tokens. Dropped the "what NOT to save" bullets, the detailed
 // 4-type taxonomy descriptions, and the verbose YAML "how to
 // save" instructions (the tool schema itself documents the
 // payload shape). Kept the persistence statement, the tightened
 // explicit-trigger rule, and the index/topics body inlining.
 // Net effect: less prompt salience for `memory_write` →
 // companion `toolGovernance` section explicitly tells the model
 // not to call it for unrelated queries → wrong-tool-call rate
 // on time / calendar / reminders queries drops.
 let fullBlock = """
 # Memory

 Persistent on-device memory. Save with `memory_write` ONLY when the user explicitly asks you to remember something ("remember that...", "save this for later"). Do not save unsolicited.

 Path conventions: `user_*.md` / `feedback_*.md` / `project_*.md` / `reference_*.md`. After writing a topic file, also rewrite `MEMORY.md` adding a one-line bullet `- [Title](file.md) — hook` (must include every existing bullet — drops are rejected).

 ## Current MEMORY.md
 \(displayedIndex)
 """
 return topicsBlock.isEmpty ? fullBlock : "\(fullBlock)\n\n\(topicsBlock)"
 }

 /// Render the `## Topic file contents` block (Round-6 R6-A.1).
 /// Topics keyed by displayName (set in `ContextBuilder` via
 /// `MemoryStore.loadRetrievalDocuments` — frontmatter pre-stripped).
 /// Sorted alphabetically by key for deterministic prompt caching.
 /// Returns empty string when no topics — caller decides whether to omit.
 private static func renderTopicsBlock(_ topics: [String: String]) -> String {
 guard !topics.isEmpty else { return "" }
 let sorted = topics.sorted() { $0.key < $1.key }
 let chunks: [String] = sorted.compactMap { (displayName, body) in
 let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmedBody.isEmpty else { return nil }
 return "### \(displayName)\n\(trimmedBody)"
 }
 guard !chunks.isEmpty else { return "" }
 return "## Topic file contents\n\(chunks.joined(separator: "\n\n"))"
 }

 private static func environmentSection(_ env: Environment) -> String {
 return """
 # Environment
 Model: \(env.model)
 Platform: \(env.platform)
 Today's date: \(env.currentDate)
 """
 }
}
