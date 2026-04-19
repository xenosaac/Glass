import Foundation

/// ToolProvider that bundles iOS-specific file-related tools.
///
/// The CC-verbatim `Read` / `Glob` / `Grep` tools live in `BuiltinToolProvider`;
/// this provider hosts the iOS-flavored extras that don't have a direct CC
/// counterpart:
/// `file_list` — directory listing
/// `file_write` — write/create files through the security-scoped bookmark store
/// `file_search` — Core Spotlight content search (system-wide index)
public struct FileToolProvider: ToolProvider, Sendable {
 public var providerName: String { "files" }
 public var source: ToolSource { .files }

 public init() {}

 public func tools(for context: ToolCallContext) async -> [any RelayTool] {
 [
 FileListTool(),
 FileWriteTool(),
 FileSearchTool(),
 ]
 }
}
