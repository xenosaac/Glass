import Foundation

/// Tool to search file contents using Core Spotlight.
public struct FileSearchTool: RelayTool, Sendable {
 public var name: String { "file_search" }
 public var description: String { "Search file contents using iOS Spotlight. Searches indexed text in PDFs, documents, notes, etc. Results may include files outside authorized folders (Spotlight indexes system-wide)." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "query": {
 "type": "string",
 "description": "Search query to find in file contents"
 },
 "folder": {
 "type": "string",
 "description": "Limit search to files in this folder path (optional)"
 },
 "limit": {
 "type": "integer",
 "description": "Maximum number of results to return (default: 10)"
 }
 },
 "required": ["query"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]
 guard let query = params["query"] as? String, !query.isEmpty else {
 return ToolResult(toolUseId: "", output: "Error: 'query' parameter is required", isError: true)
 }
 let rawFolder = params["folder"] as? String ?? ""
 let folder: String?
 if rawFolder.isEmpty && context.session.workspaceURL == nil {
 folder = nil // No folder specified, no workspace — search all authorized
 } else {
 switch WorkspacePathResolver.resolve(rawFolder, workspace: context.session.workspaceURL) {
 case .resolved(let p): folder = p
 case .error(let msg): return ToolResult(toolUseId: "", output: "Error: \(msg)", isError: true)
 }
 }
 let limit = params["limit"] as? Int ?? 10

 let fileProvider = context.services.fileProvider

 do {
 let results = try await fileProvider().searchFiles(query: query, inFolder: folder, limit: limit)

 if results.isEmpty {
 return ToolResult(toolUseId: "", output: "No files found matching '\(query)'")
 }

 let lines = results.enumerated().map { idx, result in
 "\(idx + 1). \(result.displayName)\n \(result.path)"
 }

 return ToolResult(toolUseId: "", output: lines.joined(separator: "\n"))
 } catch {
 return ToolResult(toolUseId: "", output: "Search error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .filesystem, operation: .search, summary: description)
 }
}
