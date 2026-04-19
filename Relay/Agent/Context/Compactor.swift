import Foundation

/// explicit compaction module. Keeps long-running sessions
/// sustainable on Gemma-4-E2B's small on-device working context by
/// summarizing a prefix of prior history into a single boundary
/// message whenever the estimated token count crosses a threshold.
///
/// ## Timing (load-bearing contract)
///
/// Invoked from `AgentCore.runTurn(message:continuation:)` **immediately
/// after the `[DEBUG_MEMORY]` turn-start log and BEFORE tool-gather**.
/// At that call site `state.messages` holds only prior history; the
/// just-arrived user input is still the local `message` parameter and
/// has not yet been appended. This invariant is pinned by
/// `test_compactor_timing_seesPriorHistoryOnly` in `CompactorTests`.
/// The runner later appends `message` in step 7 of `runTurn`, AFTER
/// compaction has finalized, so the brand-new user input is never
/// part of the compactor's summarization input on the same invocation.
///
/// ## Guardrails
/// Threshold (`budgetTokens`, default 8_000): only compact when the
/// estimated token count of `state.messages` is at or above this.
/// 3-strike circuit breaker (`maxFailures`, default 3): after that
/// many session-lifetime failures, no further attempts until process
/// restart. Tracking lives in
/// `state.autoCompactTracking.failureCount`.
/// Same-turn gate: at most one attempt per `runTurn` invocation.
/// Tracked in `state.autoCompactTracking.lastAttemptedAtTurnCount`.
/// Tail preservation (`tailPreserveCount`, default 4): most-recent
/// messages are kept verbatim so recent-turn continuity is never
/// weakened.
/// Tool-pair preservation: the split between summarized prefix and
/// preserved tail never cleaves a `.assistant(toolUse)` /
/// `.toolResult(...)` pair. If the natural split would do so, the
/// boundary shifts so both sides of the pair live together in the
/// tail.
///
/// Outputs:
/// `MessageFactory.compactBoundary(summary:)` produces a single
/// `isMeta: true` user message that replaces the summarized prefix.
/// `isMeta` keeps the boundary out of `turnCount` accounting and out
/// of `ChatViewModel.convertToDisplay`'s visible transcript.
public actor Compactor {

 // MARK: - Config

 public let modelClient: any ModelClient
 public let budgetTokens: Int
 public let tailPreserveCount: Int
 public let maxFailures: Int

 public init(
 modelClient: any ModelClient,
 budgetTokens: Int = 8_000,
 tailPreserveCount: Int = 4,
 maxFailures: Int = 3
 ) {
 self.modelClient = modelClient
 self.budgetTokens = budgetTokens
 self.tailPreserveCount = tailPreserveCount
 self.maxFailures = maxFailures
 }

 // MARK: - Public API

 /// Pure-ish predicate (only reads `state`; no side effects). Short-
 /// circuits on the circuit breaker and same-turn gate before doing
 /// the token estimate.
 public func shouldCompact(state: AgentSessionState) -> Bool {
 if state.autoCompactTracking.failureCount >= maxFailures { return false }
 if state.autoCompactTracking.lastAttemptedAtTurnCount == state.turnCount { return false }
 return estimateTokens(of: state.messages) >= budgetTokens
 }

 /// Attempt one compaction pass. Returns the (possibly) updated
 /// `state` and whether the summary actually replaced the prefix.
 ///
 /// Always advances `lastAttemptedAtTurnCount` before any model call
 /// so the same-turn gate engages even if the summarization throws.
 ///
 /// On failure (model throw, parse miss), bumps `failureCount` and
 /// returns the unchanged messages with updated tracking. On
 /// success, resets `failureCount` to 0 and returns messages =
 /// `[boundary] + tail`.
 public func compact(state: AgentSessionState) async -> (state: AgentSessionState, didCompact: Bool) {
 var tracking = state.autoCompactTracking
 tracking.lastAttemptedAtTurnCount = state.turnCount

 let (prefix, tail) = splitPrefixAndTail(state.messages)

 // Empty prefix means there's nothing to summarize even though
 // the threshold fired — treat as non-compacting, but keep the
 // same-turn gate update.
 guard !prefix.isEmpty else {
 var unchangedState = state
 unchangedState.autoCompactTracking = tracking
 return (unchangedState, false)
 }

 let summary: String
 do {
 summary = try await summarize(prefix: prefix)
 } catch {
 tracking.failureCount += 1
 var failedState = state
 failedState.autoCompactTracking = tracking
 return (failedState, false)
 }

 tracking.failureCount = 0
 let boundary = MessageFactory.compactBoundary(summary: summary)
 var compactedState = state
 compactedState.messages = [boundary] + tail
 compactedState.autoCompactTracking = tracking
 compactedState.summaryState = SessionSummaryState(
 latestBoundarySummary: summary,
 lastCompactedAtTurnCount: state.turnCount,
 latestBoundaryMessageIndex: 0
 )
 return (
 compactedState,
 true
 )
 }

 // MARK: - Split (pair-preserving)

 /// Split `messages` into a prefix (to summarize) and a tail (to
 /// preserve verbatim). Guarantees that no tool_use/tool_result
 /// pair is cleaved across the boundary.
 ///
 /// Rule: start with a naive split at
 /// `count - tailPreserveCount`. If the message immediately
 /// preceding the tail is an `.assistant(...)` that contains any
 /// `.toolUse(...)` block, AND the first tail message is a
 /// `.toolResult(...)`, pull the `.assistant` into the tail so the
 /// pair stays together. Symmetric: if the first tail message is a
 /// `.toolResult(...)` whose `.assistant` partner would otherwise
 /// sit at the end of the prefix, pull both.
 ///
 /// Public for testability (CompactorTests reaches in via
 /// `@testable import Relay`).
 internal func splitPrefixAndTail(_ messages: [RelayMessage]) -> (prefix: [RelayMessage], tail: [RelayMessage]) {
 guard messages.count > tailPreserveCount else {
 return ([], messages)
 }

 var splitIndex = messages.count - tailPreserveCount

 // Walk the split leftward until the boundary does not cleave
 // a tool_use/tool_result pair. Bounded by the full array so
 // we can't loop forever.
 while splitIndex > 0 && cleavesPair(messages, at: splitIndex) {
 splitIndex -= 1
 }

 let prefix = Array(messages[..<splitIndex])
 let tail = Array(messages[splitIndex...])
 return (prefix, tail)
 }

 /// Returns true when splitting at `index` (prefix = 0..<index,
 /// tail = index...) would separate an `.assistant(toolUse)` from
 /// its paired `.toolResult`.
 private func cleavesPair(_ messages: [RelayMessage], at index: Int) -> Bool {
 guard index > 0, index < messages.count else { return false }
 let lastPrefix = messages[index - 1]
 let firstTail = messages[index]

 if case .assistant(let content) = lastPrefix,
 case .toolResult = firstTail {
 return content.blocks.contains { block in
 if case .toolUse = block { return true }
 return false
 }
 }
 return false
 }

 // MARK: - Summarization side query

 private func summarize(prefix: [RelayMessage]) async throws -> String {
 var collected = ""
 for try await event in modelClient.stream(
 messages: prefix,
 tools: [],
 options: .init(maxTokens: 1024),
 systemPrompt: Self.summarizerSystemPrompt
 ) {
 switch event {
 case .token(let t):
 collected += t
 case .done(let result):
 if !result.text.isEmpty {
 collected = result.text
 }
 }
 }
 return try Self.parseSummary(from: collected)
 }

 /// Extract the body between `<summary>` and `</summary>` tags.
 /// If the model wrapped the summary as specified, this returns it
 /// trimmed. Throws `CompactorError.summaryParseFailed` otherwise.
 private static func parseSummary(from raw: String) throws -> String {
 guard let open = raw.range(of: "<summary>") else {
 throw CompactorError.summaryParseFailed
 }
 let afterOpen = raw[open.upperBound...]
 guard let close = afterOpen.range(of: "</summary>") else {
 throw CompactorError.summaryParseFailed
 }
 let body = afterOpen[..<close.lowerBound]
 let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !trimmed.isEmpty else {
 throw CompactorError.summaryParseFailed
 }
 return trimmed
 }

 /// Short, CC-style summarizer instruction. Lives here so the
 /// compactor doesn't pull on `SystemPrompt.swift`.
 private static let summarizerSystemPrompt: String = """
 You are summarizing an in-progress conversation so the model can continue with less context.
 Respond in this exact format:
 <analysis>
 brief note on what to preserve
 </analysis>
 <summary>
 dense summary of key facts, decisions, and pending tasks
 </summary>
 """

 // MARK: - Token estimator

 /// UTF-8-byte-based proxy for token count. Cheap and deterministic;
 /// conservative for English (where ~4 bytes ≈ 1 token) and still
 /// reasonable for multi-byte scripts. Media blocks count as fixed
 /// 256 tokens each, matching Gemma-4-E2B's per-attachment overhead.
 ///
 /// Internal for test visibility via `@testable import Relay`.
 internal func estimateTokens(of messages: [RelayMessage]) -> Int {
 var total = 0
 for message in messages {
 switch message {
 case .user(let content):
 for block in content.blocks {
 switch block {
 case .text(let s): total += s.utf8.count / 4
 case .audioRef: total += 256
 case .image: total += 256
 case .fileRef: continue
 }
 }
 case .assistant(let content):
 for block in content.blocks {
 switch block {
 case .text(let s): total += s.utf8.count / 4
 case .toolUse(let use): total += use.inputJson.utf8.count / 4
 }
 }
 case .toolResult(let blocks):
 for block in blocks {
 total += block.output.utf8.count / 4
 }
 }
 }
 return total
 }

 // MARK: - Errors

 public enum CompactorError: Error, Sendable, Equatable {
 case summaryParseFailed
 }
}
