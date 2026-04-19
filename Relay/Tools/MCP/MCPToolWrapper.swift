import Foundation

/// Wraps an MCP server tool as a RelayTool for the agent loop.
///
/// Tool names are namespaced to avoid collisions:
/// `mcp__{server}__{toolname}` (double underscore, mirroring the reference agent's
/// `services/mcp/mcpStringUtils.ts:50-51` convention
public struct MCPToolWrapper: RelayTool, Sendable {
 private let serverName: String
 private let definition: MCPToolDefinition
 private let client: MCPClient

 public init(serverName: String, definition: MCPToolDefinition, client: MCPClient) {
 self.serverName = serverName
 self.definition = definition
 self.client = client
 }

 // MARK: - RelayTool Conformance

 public var name: String {
 // Namespace to avoid collisions: "mcp__github__create_issue".
 // switched to double-underscore so tool names
 // align with CC + Anthropic conventions models were trained on.
 // Legacy single-underscore names are resolved via
 // `MCPToolWrapper.resolveLegacyName(_:)` for migration safety.
 "mcp__\(serverName)__\(definition.name)"
 }

 /// migration helper. Translates a legacy
 /// single-underscore name (`"mcp_<server>_<tool>"` — the pre-R7-A
 /// format) into the canonical double-underscore form when possible.
 /// Callers that hold references to the old format (e.g., persisted
 /// MCP config entries keyed by wrapper name) can use this to survive
 /// the rename. Returns nil if the input doesn't match the legacy
 /// pattern.
 public static func resolveLegacyName(
 _ legacyName: String,
 knownServers: [String]
 ) -> String? {
 guard legacyName.hasPrefix("mcp_"), !legacyName.hasPrefix("mcp__") else {
 return nil
 }
 // Try to find a matching `knownServer` prefix. Servers are the
 // authoritative delimiter because tool names themselves may
 // contain underscores.
 let tail = String(legacyName.dropFirst("mcp_".count))
 for server in knownServers where tail.hasPrefix("\(server)_") {
 let toolName = String(tail.dropFirst("\(server)_".count))
 return "mcp__\(server)__\(toolName)"
 }
 return nil
 }

 public var description: String {
 if let desc = definition.description {
 return "[\(serverName.uppercased())] \(desc)"
 }
 return "MCP tool '\(definition.name)' from \(serverName)"
 }

 public var inputSchema: ToolInputSchema {
 // sanitize the wire-format JSON Schema before
 // exposing to either model adapter (Gemini cloud or FunctionGemma
 // on-device). Canvas hosted MCP returns per-property schemas with
 // nested `additionalProperties`, which Gemini's function-calling
 // schema (an OpenAPI 3.0 subset) rejects as `INVALID_ARGUMENT`.
 // Stripped keywords are documentation/metadata only and are not
 // part of any runtime contract Glass enforces today
 // (ToolInputValidator only checks `required`). On parse failure
 // we fall back to the verbatim string — never break the existing
 // happy path.
 let raw = definition.inputSchema.toJSONString
 guard let data = raw.data(using: .utf8),
 let parsed = try? JSONSerialization.jsonObject(with: data),
 let cleaned = Self.sanitizeForCloudFunctionCalling(parsed) as? [String: Any],
 let cleanedData = try? JSONSerialization.data(withJSONObject: cleaned),
 let cleanedString = String(data: cleanedData, encoding: .utf8) else {
 return ToolInputSchema(json: raw)
 }
 return ToolInputSchema(json: cleanedString)
 }

 /// JSON Schema keywords that the cloud function-calling API (Gemini
 /// 2.5 Flash-Lite, OpenAPI 3.0 subset) rejects when nested inside a
 /// tool's parameter schema. Narrow + evidence-backed: only
 /// `additionalProperties` is device-evidence-confirmed; the four
 /// metadata keywords are safe-to-strip pure documentation that
 /// carries no tool-shape information. Structure-bearing keywords
 /// (`$ref`, `$defs`, `definitions`, `patternProperties`) are
 /// deliberately preserved — removing them would silently destroy
 /// schema structure rather than sanitize it.
 internal static let geminiIncompatibleKeywords: Set<String> = [
 "additionalProperties",
 "$schema",
 "$id",
 "$comment",
 "examples"
 ]

 /// Narrow, evidence-backed textual error prefixes used to recover
 /// from hosted MCP servers that return an error string in the first
 /// text block but forget to set `isError=true` in `tools/call`.
 /// Only trimmed-prefix matching is allowed; no broad substring
 /// matching, to avoid reclassifying legitimate content as failure.
 internal static let inferredErrorTextPrefixes: [String] = [
 "error:",
 "error ",
 "failed:",
 "failed ",
 "request failed",
 "unable to "
 ]

 /// Recursively walk a JSON value and drop blacklisted keys at every
 /// depth. Dicts → recurse into values, drop blacklisted keys. Arrays
 /// → recurse into elements. Primitives → pass through unchanged.
 /// `internal` so the regression test in
 /// `RelayTests/MCPToolWrapperNamingTests.swift` can exercise it
 /// directly via `@testable import Relay`.
 internal static func sanitizeForCloudFunctionCalling(_ value: Any) -> Any {
 if let dict = value as? [String: Any] {
 var cleaned: [String: Any] = [:]
 for (key, raw) in dict where !geminiIncompatibleKeywords.contains(key) {
 cleaned[key] = sanitizeForCloudFunctionCalling(raw)
 }
 return cleaned
 }
 if let array = value as? [Any] {
 return array.map(sanitizeForCloudFunctionCalling)
 }
 return value
 }

 internal static func firstNonEmptyText(in blocks: [MCPContentBlock]) -> String? {
 blocks
 .compactMap(\.text)
 .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
 .first { !$0.isEmpty }
 }

 internal static func inferredErrorPrefix(in blocks: [MCPContentBlock]) -> String? {
 guard let firstText = firstNonEmptyText(in: blocks)?.lowercased() else {
 return nil
 }
 return inferredErrorTextPrefixes.first { firstText.hasPrefix($0) }
 }

 internal static func shouldTreatToolCallResultAsError(_ result: MCPToolCallResult) -> Bool {
 result.isError == true || inferredErrorPrefix(in: result.content) != nil
 }

 private static func logPreview(_ text: String, limit: Int = 160) -> String {
 let flattened = text
 .replacingOccurrences(of: "\n", with: "\\n")
 .replacingOccurrences(of: "\r", with: "\\r")
 guard flattened.count > limit else { return flattened }
 let end = flattened.index(flattened.startIndex, offsetBy: limit)
 return String(flattened[..<end]) + "..."
 }

 public var isConcurrencySafe: Bool {
 // Safe if server says idempotent OR no hint and doesn't look destructive
 if let hint = definition.annotations?.idempotentHint {
 return hint
 }
 // Heuristic: destructive operations shouldn't run concurrently
 return !isDestructive
 }

 public var isReadOnly: Bool {
 // Use server annotation if available
 if let hint = definition.annotations?.readOnlyHint {
 return hint
 }
 // Heuristic: "get", "list", "read", "search", "query" are typically read-only
 let name = definition.name.lowercased()
 let readOnlyPrefixes = ["get", "list", "read", "search", "query", "fetch", "find", "show", "describe"]
 return readOnlyPrefixes.contains { name.hasPrefix($0) }
 }

 public var isDestructive: Bool {
 // Use server annotation if available
 if let hint = definition.annotations?.destructiveHint {
 return hint
 }
 // Heuristic: "delete", "remove", "drop", "destroy", "purge" are destructive
 let name = definition.name.lowercased()
 let destructiveKeywords = ["delete", "remove", "drop", "destroy", "purge", "truncate", "wipe", "clear", "reset"]
 return destructiveKeywords.contains { name.contains($0) }
 }

 /// conservative cap for third-party MCP tools of
 /// unknown shape. 10 KB fits most search/list responses; larger
 /// payloads get persisted to disk and the model re-reads on demand.
 public var maxResultSizeChars: Int { 10_000 }

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 // Parse input JSON to dictionary
 let params: [String: Any]
 if let parsed = try? JSONSerialization.jsonObject(with: input.json) as? [String: Any] {
 params = parsed
 } else {
 params = [:]
 }

 context.progress(ToolProgress(toolUseId: "", message: "Calling \(definition.name)..."))

 do {
 let result = try await client.callTool(
 name: definition.name,
 arguments: params
 )

 // Flatten content blocks to string
 let output = result.content.compactMap { block -> String? in
 if let text = block.text {
 return text
 }
 if let data = block.data, let mime = block.mimeType {
 return "[binary: \(mime), \(data.count) chars]"
 }
 if block.type == "resource" {
 return "[resource]"
 }
 return nil
 }.joined(separator: "\n")

 let inferredErrorPrefix = Self.inferredErrorPrefix(in: result.content)
 if result.isError != true,
 let inferredErrorPrefix,
 let firstText = Self.firstNonEmptyText(in: result.content) {
 print(
 "[MCP][\(serverName)] callTool server success-flag mismatch inferredError " +
 "name=\(definition.name) prefix=\(inferredErrorPrefix) preview=\(Self.logPreview(firstText))"
 )
 }

 return ToolResult(
 toolUseId: "",
 output: output.isEmpty ? "(empty result)" : output,
 isError: Self.shouldTreatToolCallResultAsError(result)
 )
 } catch let error as MCPError {
 return ToolResult(
 toolUseId: "",
 output: "MCP error: \(error.localizedDescription)",
 isError: true
 )
 } catch {
 return ToolResult(
 toolUseId: "",
 output: "MCP tool call failed: \(error.localizedDescription)",
 isError: true
 )
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 ToolPolicyDescriptor(
 domain: .mcp(server: serverName),
 operation: inferredPolicyOperation,
 risk: inferredPolicyRisk,
 summary: definition.annotations?.sideEffectDescription ?? (definition.description ?? "MCP tool '\(definition.name)' from \(serverName)"),
 targetDescription: definition.name
 )
 }

 private func inferredPolicyOperation() -> ToolPolicyOperation {
 let lowered = definition.name.lowercased()
 if isReadOnly {
 let searchPrefixes = ["search", "find", "query"]
 if searchPrefixes.contains(where: { lowered.hasPrefix($0) }) {
 return .search
 }
 return .read
 }
 if lowered.contains("delete") || lowered.contains("remove") || lowered.contains("drop") {
 return .delete
 }
 if lowered.contains("write") || lowered.contains("save") || lowered.contains("update") || lowered.contains("edit") {
 return .write
 }
 if lowered.contains("create") || lowered.contains("add") {
 return .create
 }
 if lowered.contains("send") {
 return .send
 }
 return .execute
 }

 private func inferredPolicyRisk() -> ToolPolicyRisk {
 if definition.annotations?.readOnlyHint == true {
 return .readOnly
 }
 if definition.annotations?.destructiveHint == true {
 return .destructive
 }
 if isReadOnly {
 return .readOnly
 }
 if isDestructive {
 return .destructive
 }
 return .unknown
 }
}
