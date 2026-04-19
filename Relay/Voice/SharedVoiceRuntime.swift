import Foundation

/// Shared whisper model host across all chat sessions.
/// Solves: repeated model loads per session, enables prewarm at app launch.
///
/// Lifecycle:
/// Created in SharedServices during app bootstrap
/// prewarmWhisper called in background after Gemma loads
/// VoiceEngine uses ensureWhisperReady instead of loading directly
/// Whisper stays loaded for app lifetime (expensive to reload)
@MainActor
public final class SharedVoiceRuntime: @unchecked Sendable {

 public enum WhisperState: Sendable {
 case notLoaded
 case loading
 case ready
 case failed(String)
 }

 /// Current state of the whisper model.
 public private(set) var whisperState: WhisperState = .notLoaded

 /// The shared whisper host. Only valid when state is .ready.
 private var whisperHost: CactusModelHost?

 /// Continuation for callers waiting on whisper to load.
 private var waiters: [CheckedContinuation<CactusModelHost?, Never>] = []

 public init() {}

 // MARK: - Public API

 /// Check if whisper is ready (non-blocking).
 public var isWhisperReady: Bool {
 if case .ready = whisperState { return true }
 return false
 }

 /// Prewarm whisper in background (non-blocking).
 /// Call once after app launch. Safe to call multiple times.
 public func prewarmWhisper() async {
 // Skip if already loading or ready
 switch whisperState {
 case .loading, .ready:
 print("[VOICE_PREWARM] skip — already \(whisperState)")
 return
 case .notLoaded, .failed:
 break
 }

 print("[VOICE_PREWARM] start")
 whisperState = .loading
 let startedAt = CFAbsoluteTimeGetCurrent()

 do {
 // Resolve and hydrate whisper model path
 guard let resolved = try await AppPaths.prepareWhisperSmallForLoad() else {
 let msg = "Whisper model not found in bundle or Documents"
 print("[VOICE_PREWARM] fail: \(msg)")
 whisperState = .failed(msg)
 notifyWaiters(nil)
 return
 }
 let modelPath = resolved.url.path
 let prepareMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000

 // Load the model
 let host = CactusModelHost(modelPath: modelPath)
 let loadStartedAt = CFAbsoluteTimeGetCurrent()
 try await host.load()
 let loadMs = (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000

 whisperHost = host
 whisperState = .ready
 print(
 "[VOICE_PREWARM] ready path=\(modelPath) " +
 "prepare_ms=\(String(format: "%.0f", prepareMs)) " +
 "load_ms=\(String(format: "%.0f", loadMs)) " +
 "total_ms=\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000))"
 )
 notifyWaiters(host)

 } catch {
 let msg = error.localizedDescription
 print("[VOICE_PREWARM] fail: \(msg)")
 whisperState = .failed(msg)
 notifyWaiters(nil)
 }
 }

 /// Get the whisper host, waiting if necessary.
 /// Returns nil if loading fails.
 public func ensureWhisperReady() async -> CactusModelHost? {
 switch whisperState {
 case .ready:
 return whisperHost

 case .failed:
 // Try once more
 await prewarmWhisper()
 return whisperHost

 case .notLoaded:
 // Start loading and wait
 Task { await prewarmWhisper() }
 return await withCheckedContinuation { continuation in
 waiters.append(continuation)
 }

 case .loading:
 // Already loading, wait for completion
 return await withCheckedContinuation { continuation in
 waiters.append(continuation)
 }
 }
 }

 /// Unload whisper to free memory (e.g., on memory warning).
 public func unloadWhisper() {
 whisperHost = nil
 whisperState = .notLoaded
 print("[VOICE_PREWARM] unloaded")
 }

 // MARK: - Private

 private func notifyWaiters(_ host: CactusModelHost?) {
 let pending = waiters
 waiters = []
 for waiter in pending {
 waiter.resume(returning: host)
 }
 }
}
