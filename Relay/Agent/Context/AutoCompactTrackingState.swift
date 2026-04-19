import Foundation

/// Per-session autocompact tracking. Lives inside `AgentSessionState`
/// so the compactor's guardrails thread through the same state
/// container the runner already manages.
///
/// two fields only — just enough to drive the 3-strike
/// circuit breaker and the same-turn gate. Not persisted across
/// process launches; counters reset at app boot. Boundary messages
/// themselves DO persist via the normal JSONL `.user` path because
/// `MessageFactory.compactBoundary(summary:)` produces a regular
/// `RelayMessage.user(..., isMeta: true)` value.
///
/// Explicitly NOT included this phase:
/// `lastCompactedAtTurnCount` — no reader. Add when a
/// caller needs it.
/// Persisted cross-session tracking — resetting per process is
/// acceptable today because boundary messages already carry the
/// summarized state forward.
public struct AutoCompactTrackingState: Sendable, Equatable {
 /// Number of failed compaction attempts in this session. Bumped
 /// by `Compactor.compact(state:)` when the summarization stream
 /// throws or the summary fails to parse. Reaching `maxFailures`
 /// (default 3 in `Compactor`) locks out further attempts for the
 /// remainder of the session.
 public var failureCount: Int

 /// The `state.turnCount` value at which the most recent
 /// compaction attempt ran — regardless of success. Used to gate
 /// "don't retry within the same turn" so a transient failure
 /// can't spin the compactor repeatedly within one `runTurn`
 /// invocation.
 public var lastAttemptedAtTurnCount: Int

 public init(failureCount: Int = 0, lastAttemptedAtTurnCount: Int = 0) {
 self.failureCount = failureCount
 self.lastAttemptedAtTurnCount = lastAttemptedAtTurnCount
 }

 /// Zero-initialized tracking — the default starting state for a
 /// fresh session or a post-`hydrate` session.
 public static var empty: AutoCompactTrackingState {
 AutoCompactTrackingState
 }
}
