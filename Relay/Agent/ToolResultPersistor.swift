import Foundation

/// port of the reference agent's tool-result-persistence layer
/// (`utils/toolResultStorage.ts`). When a tool returns more output than its
/// `maxResultSizeChars` allows, the full body is written to disk and the
/// in-conversation content is replaced with a `<persisted-output>` preview
/// wrapper. The model can re-read the full file via `FileReadTool` because
/// persistence lives under `MemoryStore.defaultRoot`, which is on the
/// FileReadTool allow-list (`Relay/Tools/Builtin/FileReadTool.swift:212-220`).
///
/// Wrapper format mirrors CC's `toolResultStorage.ts:189-199` so future
/// audits can reuse the same parsing patterns.
public enum ToolResultPersistor {

 /// Bytes shown in the inline preview when output is persisted.
 /// Matches CC's `PREVIEW_SIZE_BYTES = 2000` at `toolResultStorage.ts:109`.
 public static let previewSizeBytes = 2_000

 /// Aggregate per-message budget across all tool results in one
 /// dispatched batch. Matches CC's
 /// `MAX_TOOL_RESULTS_PER_MESSAGE_CHARS = 200_000` at
 /// `utils/toolLimits.ts:49`. Eviction policy: largest-first
 /// (CC `selectFreshToReplace` at `toolResultStorage.ts:675-691`).
 public static let aggregateBudgetChars = 200_000

 /// Wrapper tags — verbatim from CC `toolResultStorage.ts:30-31`.
 private static let openTag = "<persisted-output>"
 private static let closeTag = "</persisted-output>"

 /// If `output` exceeds `maxResultSizeChars`, persist the full body to
 /// disk and return a preview wrapper. Otherwise return the output
 /// unchanged. EEXIST-skip mirrors CC's once-only behavior at
 /// `toolResultStorage.ts:161-172` so re-runs of the same `toolUseId`
 /// don't rewrite the file.
 public static func persistIfOversized(
 toolName: String,
 toolUseId: String,
 sessionId: String,
 output: String,
 maxResultSizeChars: Int
 ) -> String {
 guard output.count > maxResultSizeChars else { return output }

 let dir = MemoryStore.defaultRoot
 .appendingPathComponent("tool-results", isDirectory: true)
 .appendingPathComponent(sessionId, isDirectory: true)
 try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

 let url = dir.appendingPathComponent("\(toolUseId).txt")
 let preexisting = FileManager.default.fileExists(atPath: url.path)
 if !preexisting {
 try? output.write(to: url, atomically: true, encoding: .utf8)
 }
 print("[ToolResult] persist fired tool=\(toolName) use_id=\(toolUseId) size=\(output.count) cap=\(maxResultSizeChars) path=\(url.path)\(preexisting ? " (EEXIST-skip)" : "")")

 return wrap(output: output, fullPath: url.path)
 }

 /// Aggregate-budget enforcement for a batch of already-bounded tool
 /// results. If the total chars across all `outputs` exceed
 /// `aggregateBudgetChars`, the largest results are persisted (or
 /// re-persisted) until the total fits. Returns the new outputs in
 /// the same order they were passed.
 ///
 /// Inputs MUST already have their per-tool cap applied; this only
 /// handles the case where multiple under-cap tools combined still
 /// blow the per-message budget.
 public static func enforceAggregateBudget(
 outputs: [(toolName: String, toolUseId: String, output: String)],
 sessionId: String
 ) -> [String] {
 let total = outputs.reduce(0) { $0 + $1.output.count }
 guard total > aggregateBudgetChars else {
 return outputs.map(\.output)
 }

 print("[ToolResult] aggregate budget exceeded total=\(total) cap=\(aggregateBudgetChars) batch_size=\(outputs.count)")

 // Sort indices by output size descending; persist largest first
 // until the total fits.
 var modified: [String?] = Array(repeating: nil, count: outputs.count)
 var residualTotal = total
 let indicesBySize = outputs.indices.sorted() { outputs[$0].output.count > outputs[$1].output.count }
 for idx in indicesBySize where residualTotal > aggregateBudgetChars {
 let entry = outputs[idx]
 print("[ToolResult] aggregate evict tool=\(entry.toolName) use_id=\(entry.toolUseId) size=\(entry.output.count) residual_before=\(residualTotal)")
 // Force-persist with a tight cap so the wrapper is short.
 let wrapped = persistIfOversized(
 toolName: entry.toolName,
 toolUseId: entry.toolUseId,
 sessionId: sessionId,
 output: entry.output,
 maxResultSizeChars: previewSizeBytes
 )
 residualTotal -= entry.output.count
 residualTotal += wrapped.count
 modified[idx] = wrapped
 }
 print("[ToolResult] aggregate budget settled residual=\(residualTotal)")
 return outputs.enumerated().map { (i, e) in modified[i] ?? e.output }
 }

 private static func wrap(output: String, fullPath: String) -> String {
 let preview = String(output.prefix(previewSizeBytes))
 let sizeKB = Double(output.count) / 1024.0
 let hasMore = output.count > previewSizeBytes ? "...\n" : ""
 return """
 \(openTag)
 Output too large (\(String(format: "%.1f", sizeKB)) KB). Full output saved to: \(fullPath)

 Preview (first \(previewSizeBytes) bytes):
 \(preview)
 \(hasMore)\(closeTag)
 """
 }
}
