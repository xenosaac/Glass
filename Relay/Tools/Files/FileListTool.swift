import Foundation

/// Tool to list directory contents in authorized folders.
public struct FileListTool: RelayTool, Sendable {
 public var name: String { "file_list" }
 public var description: String { "List files and subdirectories in an authorized folder. Returns name, path, type (file/directory), size, and modification date." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "path": {
 "type": "string",
 "description": "Absolute path to the directory to list"
 },
 "recursive": {
 "type": "boolean",
 "description": "List recursively including subdirectories (default: false)"
 },
 "includeHidden": {
 "type": "boolean",
 "description": "Include hidden files starting with . (default: false)"
 }
 },
 "required": ["path"]
 }
 """#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }

 public init() {}

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let params = (try? JSONSerialization.jsonObject(with: input.json)) as? [String: Any] ?? [:]
 let rawPath = params["path"] as? String ?? ""
 let path: String
 switch WorkspacePathResolver.resolve(rawPath, workspace: context.session.workspaceURL) {
 case .resolved(let p): path = p
 case .error(let msg): return ToolResult(toolUseId: "", output: "Error: \(msg)", isError: true)
 }
 let recursive = params["recursive"] as? Bool ?? false
 let includeHidden = params["includeHidden"] as? Bool ?? false

 context.progress(ToolProgress(toolUseId: "", message: "Listing \(URL(fileURLWithPath: path).lastPathComponent)/..."))

 let fileProvider = context.services.fileProvider

 guard await fileProvider().isAuthorized(path: path) else {
 return ToolResult(
 toolUseId: "",
 output: "Error: Path '\(path)' is not in an authorized folder. The user must grant access to this folder first.",
 isError: true
 )
 }

 do {
 let entries = try await fileProvider().listDirectory(at: path, recursive: recursive, includeHidden: includeHidden)

 if entries.isEmpty {
 return ToolResult(toolUseId: "", output: "Directory is empty.")
 }

 let formatter = ByteCountFormatter()
 formatter.countStyle = .file

 let lines = entries.map { entry -> String in
 let typeStr = entry.isDirectory ? "[DIR]" : "[FILE]"
 let sizeStr = entry.isDirectory ? "" : " (\(formatter.string(fromByteCount: entry.size)))"
 return "\(typeStr) \(entry.name)\(sizeStr)"
 }

 return ToolResult(toolUseId: "", output: lines.joined(separator: "\n"))
 } catch {
 return ToolResult(toolUseId: "", output: "Error listing directory: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .filesystem, operation: .read, summary: description)
 }
}
