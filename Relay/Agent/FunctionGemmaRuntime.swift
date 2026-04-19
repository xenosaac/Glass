import Foundation

/// Shared lazy runtime for the on-device FunctionGemma specialist model.
/// Loading is intentionally decoupled from primary Gemma bootstrap so
/// the app can still boot even when the specialist weights are missing.
internal actor SharedFunctionGemmaRuntime {
 private var host: CactusModelHost?
 private var loadTask: Task<CactusModelHost?, Never>?
 private var lastFailureReasonStorage: String?

 internal func ensureReady(trigger: String = "on_demand") async -> CactusModelHost? {
 if let host {
 return host
 }
 if let loadTask {
 return await loadTask.value
 }

 let task = Task<CactusModelHost?, Never> {
 let startedAt = CFAbsoluteTimeGetCurrent()
 print("[FUNC_PREWARM] start trigger=\(trigger)")
 do {
 guard let prepared = try await AppPaths.prepareFunctionGemmaForLoad() else {
 recordFailure("FunctionGemma-270M is missing from the app bundle or Documents fallback.")
 return nil
 }
 let modelPath = prepared.url.path
 let prepareMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
 #if DEBUG
 print("MODEL_RESOLVE functiongemma source=\(prepared.source.rawValue) path=\(modelPath)")
 #endif
 let host = CactusModelHost(modelPath: modelPath)
 let loadStartedAt = CFAbsoluteTimeGetCurrent()
 try await host.load()
 let loadMs = (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000
 setLoadedHost(host)
 print(
 "[FUNC_PREWARM] ready source=\(prepared.source.rawValue) " +
 "trigger=\(trigger) prepare_ms=\(String(format: "%.0f", prepareMs)) " +
 "load_ms=\(String(format: "%.0f", loadMs)) " +
 "total_ms=\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000))"
 )
 return host
 } catch {
 recordFailure("Failed to load FunctionGemma-270M: \(error.localizedDescription)")
 print(
 "[FUNC_PREWARM] fail trigger=\(trigger) total_ms=\(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)) " +
 "error=\(error.localizedDescription)"
 )
 return nil
 }
 }

 loadTask = task
 let loadedHost = await task.value
 loadTask = nil
 return loadedHost
 }

 internal func prewarmIfAvailable(trigger: String = "startup") async {
 _ = await ensureReady(trigger: trigger)
 }

 internal func lastFailureReason() -> String? {
 lastFailureReasonStorage
 }

 private func setLoadedHost(_ host: CactusModelHost) {
 self.host = host
 self.lastFailureReasonStorage = nil
 }

 private func recordFailure(_ message: String) {
 self.lastFailureReasonStorage = message
 }
}
