import XCTest
@testable import Relay

/// Unit tests for SharedVoiceRuntime state machine.
/// Tests focus on state transitions, not actual model loading (which requires device).
@MainActor
final class SharedVoiceRuntimeTests: XCTestCase {

 var runtime: SharedVoiceRuntime!

 override func setUp() async throws {
 runtime = SharedVoiceRuntime
 }

 override func tearDown() async throws {
 runtime = nil
 }

 // MARK: - Initial State

 func testInitialStateIsNotLoaded() {
 // Given: a fresh runtime
 // Then: state should be .notLoaded
 if case .notLoaded = runtime.whisperState {
 // Pass
 } else {
 XCTFail("Expected .notLoaded, got \(runtime.whisperState)")
 }
 }

 func testIsWhisperReadyReturnsFalseWhenNotLoaded() {
 // Given: a fresh runtime in .notLoaded state
 // Then: isWhisperReady should be false
 XCTAssertFalse(runtime.isWhisperReady)
 }

 // MARK: - Unload

 func testUnloadResetsStateToNotLoaded() {
 // Given: runtime in any state (we can't easily get to .ready without real model)
 // When: unloadWhisper is called
 runtime.unloadWhisper

 // Then: state should be .notLoaded
 if case .notLoaded = runtime.whisperState {
 // Pass
 } else {
 XCTFail("Expected .notLoaded after unload, got \(runtime.whisperState)")
 }
 XCTAssertFalse(runtime.isWhisperReady)
 }

 // MARK: - State Enum Equatable

 func testWhisperStateNotLoadedEquatable() {
 let state1: SharedVoiceRuntime.WhisperState = .notLoaded
 let state2: SharedVoiceRuntime.WhisperState = .notLoaded
 // WhisperState is Sendable but we can pattern match
 if case .notLoaded = state1, case .notLoaded = state2 {
 // Both are .notLoaded - pass
 } else {
 XCTFail("Expected both states to be .notLoaded")
 }
 }

 func testWhisperStateLoadingEquatable() {
 let state: SharedVoiceRuntime.WhisperState = .loading
 if case .loading = state {
 // Pass
 } else {
 XCTFail("Expected .loading")
 }
 }

 func testWhisperStateFailedContainsMessage() {
 let state: SharedVoiceRuntime.WhisperState = .failed("Test error")
 if case .failed(let message) = state {
 XCTAssertEqual(message, "Test error")
 } else {
 XCTFail("Expected .failed with message")
 }
 }
}
