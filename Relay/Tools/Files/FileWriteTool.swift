import Foundation

/// Tool to write content to files in authorized folders.
public struct FileWriteTool: RelayTool, Sendable {
 public var name: String { "file_write" }
 public var description: String { "Write content to a file in an authorized folder. Creates parent directories if needed. Can overwrite existing files." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "path": {
 "type": "string",
 "description": "Absolute path for the file to write"
 },
 "content": {
 "type": "string",
 "description": "Content to write to the file"
 },
 "encoding": {
 "type": "string",
 "enum": ["utf8", "base64"],
 "description": "Encoding of content (default: utf8, use base64 for binary)"
 },
 "createIntermediates": {
 "type": "boolean",
 "description": "Create parent directories if missing (default: true)"
 }
 },
 "required": ["path", "content"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { false } // Writes are serial
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { true } // Can overwrite files

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]
 let rawPath = params["path"] as? String ?? ""
 let path: String
 switch WorkspacePathResolver.resolve(rawPath, workspace: context.session.workspaceURL) {
 case .resolved(let p): path = p
 case .error(let msg): return ToolResult(toolUseId: "", output: "Error: \(msg)", isError: true)
 }
 guard let content = params["content"] as? String else {
 return ToolResult(toolUseId: "", output: "Error: 'content' parameter is required", isError: true)
 }
 let encoding = params["encoding"] as? String ?? "utf8"
 let createIntermediates = params["createIntermediates"] as? Bool ?? true

 let fileProvider = context.services.fileProvider

 guard await fileProvider().isAuthorized(path: path) else {
 return ToolResult(
 toolUseId: "",
 output: "Error: Path '\(path)' is not in an authorized folder. The user must grant access to this folder first.",
 isError: true
 )
 }

 let data: Data
 if encoding == "base64" {
 guard let decoded = Data(base64Encoded: content) else {
 return ToolResult(toolUseId: "", output: "Error: Invalid base64 content", isError: true)
 }
 data = decoded
 } else {
 guard let encoded = content.data(using: .utf8) else {
 return ToolResult(toolUseId: "", output: "Error: Content cannot be encoded as UTF-8", isError: true)
 }
 data = encoded
 }

 do {
 try await fileProvider().writeFile(at: path, data: data, createIntermediates: createIntermediates)
 return ToolResult(toolUseId: "", output: "Successfully wrote \(data.count) bytes to \(path)")
 } catch {
 return ToolResult(toolUseId: "", output: "Error writing file: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]
 let rawPath = params["path"] as? String ?? "(unknown)"
 let target: String
 switch WorkspacePathResolver.resolve(rawPath, workspace: context.session.workspaceURL) {
 case .resolved(let path):
 target = path
 case .error:
 target = rawPath
 }
 return .destructive(
 domain: .filesystem,
 operation: .write,
 summary: description,
 targetDescription: target
 )
 }
}
