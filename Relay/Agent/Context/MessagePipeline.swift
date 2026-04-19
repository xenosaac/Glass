import Foundation

/// Ordered sequence of message transforms applied to conversation
/// history before each model call.
///
/// scoped to what Relay needs today:
/// 1. Truncate with tool-pair awareness (never split a tool_use
/// from its tool_result).
/// 2. Pair repair: dedupe tool_use IDs across messages, inject
/// synthetic placeholders for missing results, strip orphaned
/// results. Delegates to `CactusModelHost.ensureToolResultPairing`.
/// 3. Smoosh `<system-reminder>` siblings (identity pass today;
/// delegates to `CactusModelHost.smooshSystemReminderSiblings`,
/// kept as a pipeline slot).
/// 4. Inject per-turn `<system-reminder>` guidance into the latest
/// user block (truncation notice + image-presence flag + focus
/// anchor).
///
/// extraction: the two private helpers (`truncateWithBoundaries`
/// and `prependSystemReminder`) are verbatim moves of the helpers
/// previously living inside `AgentCore` at lines 408–507 and 454–507
/// respectively. `transform(_:)`'s return value must be byte-identical
/// to `AgentCore.runTurn`'s former `messagesWithContext` value at
/// lines 255–258 for any given input — that invariant is the whole
/// point of this extraction.
public struct MessagePipeline: Sendable {

 /// Max messages sent to the model per iteration. Full history is
 /// retained elsewhere (in `AgentCore.messages`) for persistence.
 /// Matches the former `AgentCore.maxContextMessages` constant.
 public static let maxContextMessages = 40

 public init() {}

 /// Run the four-stage pipeline. Returns the transformed messages
 /// plus whether truncation happened (the reminder stage uses it to
 /// conditionally inject a truncation notice).
 public func transform(_ messages: [RelayMessage]) -> (messages: [RelayMessage], wasTruncated: Bool) {
 let (rawWindow, wasTruncated) = truncateWithBoundaries(messages, maxCount: Self.maxContextMessages)
 let (paired, _) = CactusModelHost.ensureToolResultPairing(rawWindow)
 let smooshed = CactusModelHost.smooshSystemReminderSiblings(paired)
 let withReminders = prependSystemReminder(to: smooshed, wasTruncated: wasTruncated)
 return (withReminders, wasTruncated)
 }

 // MARK: - Moved helpers

 /// Truncate messages while keeping tool_use/tool_result pairs together.
 /// Unlike simple suffix truncation, this ensures we never split a
 /// tool call from its result. Verbatim move from former
 /// `AgentCore.truncateWithBoundaries`.
 private func truncateWithBoundaries(_ messages: [RelayMessage], maxCount: Int) -> (messages: [RelayMessage], wasTruncated: Bool) {
 guard messages.count > maxCount else { return (messages, false) }

 var safeStart = messages.count - maxCount

 // Walk forward to find safe boundary (don't split tool pairs)
 while safeStart < messages.count {
 let msg = messages[safeStart]

 // Collect tool_use IDs in proposed window
 var windowToolUseIds = Set<String>()
 for i in safeStart..<messages.count {
 if case .assistant(let content) = messages[i] {
 for block in content.blocks {
 if case .toolUse(let use) = block { windowToolUseIds.insert(use.id) }
 }
 }
 }

 // If starting at toolResult, check its tool_use is in window
 if case .toolResult(let results) = msg {
 if results.contains(where: { !windowToolUseIds.contains($0.toolUseId) }) {
 safeStart += 1
 continue
 }
 }

 // If starting at assistant with tool_use, check results are in window
 if case .assistant(let content) = msg {
 let useIds = content.blocks.compactMap { block -> String? in
 if case .toolUse(let u) = block { return u.id }
 return nil
 }
 if !useIds.isEmpty {
 var windowResultIds = Set<String>()
 for i in safeStart..<messages.count {
 if case .toolResult(let r) = messages[i] {
 for res in r { windowResultIds.insert(res.toolUseId) }
 }
 }
 if useIds.contains(where: { !windowResultIds.contains($0) }) {
 safeStart += 1
 continue
 }
 }
 }
 break
 }

 if safeStart >= messages.count { safeStart = messages.count - maxCount }
 return (Array(messages.suffix(from: safeStart)), true)
 }

 /// Embed a **terse** per-turn `<system-reminder>` anchor as a sibling text
 /// block inside the latest user message. Prompt-surgery pass collapsed this
 /// from 3-4 meta-instruction lines to a single `Reply to: "<anchor>"` line.
 ///
 /// Rationale: on Gemma-4-E2B CPU, a 120-token meta block appended to a
 /// 4-token user turn drowned the user's actual intent in the softmax
 /// attention. The weak model's attention latches to its own phrasing
 /// (quoted anchor) much more reliably than to meta-rules that repeat what
 /// the system prompt already says. Static rules for "no image on text
 /// turn" / "answer the current message" / "don't switch to generic help"
 /// live in `SystemPrompt.multimodalSection` and `answeringSection`.
 ///
 /// Display is handled in `ChatViewModel.convertToDisplay`, which strips
 /// the reminder tag out of user bubbles before rendering.
 private func prependSystemReminder(
 to messages: [RelayMessage],
 wasTruncated: Bool
 ) -> [RelayMessage] {
 // skip `isMeta == true` user messages in BOTH
 // loops. Without this, the post-tool synthesis reminder (also a
 // meta user message, injected by AgentRunner after every
 // `.toolResult` batch) would (a) become the anchor source — so
 // `Reply to: "..."` would quote the reminder text instead of the
 // real user question — and (b) get a SECOND `Reply to:` block
 // appended onto it. Both corrupt the prompt shape.
 let latestUserTextAnchor: String? = {
 for msg in messages.reversed() {
 guard case .user(let content) = msg, !content.isMeta else { continue }
 let text = content.blocks.compactMap { block -> String? in
 if case .text(let t) = block { return t }
 return nil
 }.joined(separator: " ")
 let collapsed = text.replacingOccurrences(
 of: #"\s+"#,
 with: " ",
 options: .regularExpression
 ).trimmingCharacters(in: .whitespacesAndNewlines)
 guard !collapsed.isEmpty else { continue }
 let escaped = collapsed.replacingOccurrences(of: "\"", with: "'")
 let limit = 160
 if escaped.count > limit {
 return String(escaped.prefix(limit)) + "..."
 }
 return escaped
 }
 return nil
 }()

 guard let anchor = latestUserTextAnchor else { return messages }

 let reminderLine = wasTruncated
 ? "Earlier turns truncated. Reply to: \"\(anchor)\""
 : "Reply to: \"\(anchor)\""
 let reminderText = MessageFactory.wrapInSystemReminder(reminderLine)

 var result = messages
 for i in stride(from: result.count - 1, through: 0, by: -1) {
 if case .user(let content) = result[i], !content.isMeta {
 var newBlocks = content.blocks
 newBlocks.append(.text(reminderText))
 result[i] = .user(UserContent(blocks: newBlocks, isMeta: content.isMeta))
 return result
 }
 }
 return result
 }
}
