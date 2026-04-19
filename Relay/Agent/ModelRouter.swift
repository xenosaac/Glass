import Foundation

/// Decides which model tier to use for a given turn.
///
/// For now: always returns `.fast` (Gemma-4-E2B on-device).
/// E4B was dropped due to M1 Pro RAM constraints.
/// If the model signals `cloudHandoff`, returns `.cloud` (Gemini fallback).
public struct ModelRouter: Sendable {
 public private(set) var lastReason: String = "E2B on-device"

 public mutating func decide(cloudHandoffSuggested: Bool) -> ModelTier {
 if cloudHandoffSuggested {
 lastReason = "model requested cloud handoff"
 return .cloud
 }
 lastReason = "E2B on-device"
 return .fast
 }
}
