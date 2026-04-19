import Foundation

/// Centralized factories for building `RelayMessage` values.
///
/// `createToolResultMessage` (`utils/messages.ts:411-523`) into a single Swift
/// namespace. Call sites that previously constructed enum cases directly should
/// route through here so the `isMeta` flag, `<system-reminder>` wrapping, and
/// other invariants stay in one place.
public enum MessageFactory {

 private struct AttachmentChunkPayload: Encodable {
 let source: String
 let position: Int
 let totalChunks: Int
 let text: String
 }

 private struct ContextArtifactPayload: Encodable {
 let id: String
 let kind: String
 let source: String
 let tokenEstimate: Int
 let position: Int?
 let totalParts: Int?
 let text: String
 }

 // MARK: - System-reminder wrapping

 /// Idempotent `<system-reminder>` wrapping. Ports `ensureSystemReminderWrap`
 /// / `wrapInSystemReminder` (`utils/messages.ts:1797-1817`). Already-wrapped
 /// bodies are returned unchanged — this lets callers compose without
 /// worrying about double-wrapping.
 public static func wrapInSystemReminder(_ body: String) -> String {
 if body.hasPrefix("<system-reminder>") { return body }
 return "<system-reminder>\n\(body)\n</system-reminder>"
 }

 // MARK: - User messages

 /// Plain text user turn. `isMeta: true` sends the message to the model but
 /// hides it from the chat transcript.
 public static func userText(_ text: String, isMeta: Bool = false) -> RelayMessage {
 .user(UserContent(blocks: [.text(text)], isMeta: isMeta))
 }

 /// System reminder injected as a meta user message. Always `isMeta: true`
 /// and always wrapped in `<system-reminder>` tags. Prefer this over
 /// constructing reminders by hand.
 public static func userSystemReminder(_ body: String) -> RelayMessage {
 .user(UserContent(
 blocks: [.text(wrapInSystemReminder(body))],
 isMeta: true
 ))
 }

 /// Multimodal user turn preserving attachment order.
 public static func userBlocks(_ blocks: [UserBlock], isMeta: Bool = false) -> RelayMessage {
 .user(UserContent(blocks: blocks, isMeta: isMeta))
 }

 // MARK: - Assistant messages

 public static func assistantText(_ text: String) -> RelayMessage {
 .assistant(AssistantContent(blocks: [.text(text)]))
 }

 public static func assistantToolUses(_ uses: [ToolUseBlock]) -> RelayMessage {
 .assistant(AssistantContent(blocks: uses.map { .toolUse($0) }))
 }

 // MARK: - Tool results

 public static func toolResults(_ blocks: [ToolResultBlock]) -> RelayMessage {
 .toolResult(blocks)
 }

 /// Synthetic placeholder for a missing tool result, used by the pairing
 /// repair path. Mirrors `SYNTHETIC_TOOL_RESULT_PLACEHOLDER` at
 /// `utils/messages.ts:246` with `is_error: true`.
 public static func syntheticToolResult(for toolUseId: String) -> ToolResultBlock {
 ToolResultBlock(
 toolUseId: toolUseId,
 output: syntheticToolResultPlaceholder,
 isError: true
 )
 }

 public static let syntheticToolResultPlaceholder =
 "[Tool result missing due to internal error]"

 // MARK: - Synthetic tool-result factories

 /// Single construction site for the five synthetic `ToolResultBlock`
 /// values that `ToolDispatcher` produces when it cannot actually
 /// execute a tool. Output strings are exact byte-for-byte copies of
 /// the prior inline literals in `ToolDispatcher.callTool` so
 /// observable model input stays unchanged.
 ///
 /// All five return `isError: true` and pass through the caller-
 /// supplied `toolUseId` so pairing with the assistant's `tool_use`
 /// block remains valid and `ensureToolResultPairing` downstream is
 /// unaffected.

 /// Tool name not present in the registry for this turn.
 /// Matches the prior `ToolDispatcher.notFoundResult` literal.
 public static func syntheticToolNotFound(toolUseId: String, toolName: String) -> ToolResultBlock {
 ToolResultBlock(
 toolUseId: toolUseId,
 output: "Tool '\(toolName)' not found in registry",
 isError: true
 )
 }

 /// `ApprovalBroker.evaluate(...)` returned `.deny(reason:)`.
 /// Matches the prior inline `"Permission denied: \(reason)"` literal.
 public static func syntheticToolDenied(toolUseId: String, reason: String) -> ToolResultBlock {
 ToolResultBlock(
 toolUseId: toolUseId,
 output: "Permission denied: \(reason)",
 isError: true
 )
 }

 /// Approval broker returned `.confirm(...)` but no confirmation
 /// handler was registered. Matches the prior inline
 /// `"Confirmation required: \(prompt). No confirmation handler available."` literal.
 public static func syntheticConfirmationRequired(toolUseId: String, prompt: String) -> ToolResultBlock {
 ToolResultBlock(
 toolUseId: toolUseId,
 output: "Confirmation required: \(prompt). No confirmation handler available.",
 isError: true
 )
 }

 /// User answered the confirmation prompt with "deny". Matches the
 /// prior inline `"User denied: \(prompt)"` literal.
 public static func syntheticUserDenied(toolUseId: String, prompt: String) -> ToolResultBlock {
 ToolResultBlock(
 toolUseId: toolUseId,
 output: "User denied: \(prompt)",
 isError: true
 )
 }

 /// Tool's `call(...)` threw. Matches the prior inline
 /// `"Tool error: \(error.localizedDescription)"` literal.
 public static func syntheticToolError(toolUseId: String, error: Error) -> ToolResultBlock {
 ToolResultBlock(
 toolUseId: toolUseId,
 output: "Tool error: \(error.localizedDescription)",
 isError: true
 )
 }

 /// Live interruption cleanup result. Used when a turn is cancelled after
 /// assistant tool-use intent was already committed but before matching
 /// tool results were appended.
 public static func syntheticToolInterrupted(toolUseId: String) -> ToolResultBlock {
 ToolResultBlock(
 toolUseId: toolUseId,
 output: "Tool interrupted before result",
 isError: true
 )
 }

 // MARK: - Compact boundary

 /// compaction boundary. Returned by `Compactor.compact(state:)`
 /// to replace a summarized prefix of prior history. Wraps the
 /// summary in a `<compact-boundary>…</compact-boundary>` marker and
 /// emits an `isMeta: true` user message so:
 /// `AgentSessionState.derivedTurnCount(from:)` excludes it (does
 /// not bump `turnCount` on hydrate);
 /// `AgentRunner.run(...)` would not bump `turnCount` either if
 /// someone ever re-submitted it, matching the meta-user
 /// rule;
 /// `ChatViewModel.convertToDisplay`'s existing `!isMeta` filter
 /// hides it from the visible transcript (same rule that hides
 /// `<system-reminder>` injections).
 ///
 /// Pairing-safe: this is a plain `.user(...)` message, not a
 /// `.toolResult(...)`, so `ensureToolResultPairing` ignores it.
 public static func compactBoundary(summary: String) -> RelayMessage {
 .user(UserContent(
 blocks: [.text("<compact-boundary>\n\(summary)\n</compact-boundary>")],
 isMeta: true
 ))
 }

 // MARK: - Attachment chunk

 /// attachment-chunk injection. Returned by
 /// `ContextBuilder.build(state:)` for each `SelectedChunk` the
 /// `RetrievalPlanner` picks, then spliced into `ModelRequest.messages`
 /// immediately before the last non-meta user message.
 ///
 /// Emits an `isMeta: true` user message so:
 /// `AgentSessionState.derivedTurnCount(from:)` excludes it (
 /// meta-user rule),
 /// `ChatViewModel.convertToDisplay`'s existing `!isMeta` filter
 /// hides it from the visible transcript — same contract as
 /// `compactBoundary(summary:)`.
 ///
 /// Pairing-safe: plain `.user(...)` message, so
 /// `ensureToolResultPairing` ignores it.
 public static func attachmentChunk(
 text: String,
 source: String,
 position: Int,
 totalChunks: Int
 ) -> RelayMessage {
 contextArtifact(
 ContextArtifact(
 id: "attachment-\(position)",
 kind: .attachment,
 sourceDisplayName: source,
 text: text,
 tokenEstimate: max(1, text.lengthOfBytes(using: .utf8) / 4),
 position: position,
 totalParts: totalChunks
 )
 )
 }

 public static func contextArtifact(_ artifact: ContextArtifact) -> RelayMessage {
 let payload = ContextArtifactPayload(
 id: artifact.id,
 kind: artifact.kind.rawValue,
 source: artifact.sourceDisplayName,
 tokenEstimate: artifact.tokenEstimate,
 position: artifact.position,
 totalParts: artifact.totalParts,
 text: artifact.text
 )
 let encoder = JSONEncoder()
 encoder.outputFormatting = [.sortedKeys]
 let json = (try? encoder.encode(payload))
 .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
 let tagSafeJSON = makeTagSafe(json)
 let wrapped = """
 <context-artifact>
 \(tagSafeJSON)
 </context-artifact>
 """
 return .user(UserContent(
 blocks: [.text(wrapped)],
 isMeta: true
 ))
 }

 private static func makeTagSafe(_ text: String) -> String {
 text
 .replacingOccurrences(of: "&", with: "\\u0026")
 .replacingOccurrences(of: "<", with: "\\u003C")
 .replacingOccurrences(of: ">", with: "\\u003E")
 }
}
