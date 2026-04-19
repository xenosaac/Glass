import Foundation

///
/// Description is verbatim from `tools/GlobTool/prompt.ts:3-7`. Pattern
/// syntax is the subset needed for Gemma's usage: `*`, `**`, `?`, and
/// character classes. VCS + build-artifact directories are always excluded.
/// Results sort newest-first by `modificationDate`, capped at 100.
///
/// Permission: path must be inside an authorized workspace folder (via
/// `FileProvider`) or the on-device memory directory.
public struct GlobTool: RelayTool, Sendable {

 public var name: String { "Glob" }

 public var description: String {
 // Verbatim from tools/GlobTool/prompt.ts:3-7.
 """
 - Fast file pattern matching tool that works with any codebase size
 - Supports glob patterns like "**/*.js" or "src/**/*.ts"
 - Returns matching file paths sorted by modification time
 - Use this tool when you need to find files by name patterns
 - When you are doing an open ended search that may require multiple rounds of globbing and grepping, use the Agent tool instead
 """
 }

 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: """
 {
 "type": "object",
 "properties": {
 "pattern": {
 "type": "string",
 "description": "The glob pattern to match files against"
 },
 "path": {
 "type": "string",
 "description": "The directory to search in. If not specified, the first authorized workspace folder is used. IMPORTANT: Omit this field to use the default directory. DO NOT enter \\"undefined\\" or \\"null\\" - simply omit it for the default behavior. Must be a valid directory path if provided."
 }
 },
 "required": ["pattern"]
 }
 """)
 }

 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }
 /// file-list output shape ≈ 60-100 chars per path;
 /// 2 KB ≈ 20-30 paths visible with the rest in the persisted file.
 public var maxResultSizeChars: Int { 2_000 }

 public init() {}

 /// Hard result cap per call. Matches CC's 100-file default for Glob.
 public static let maxResults = 100

 /// Directories that are always skipped during enumeration. Matches CC's
 /// VCS + common build-artifact excludes; extra iOS-specific entries
 /// (`.swiftpm`, `.build`) included so Xcode-adjacent workspaces behave.
 public static let excludedDirectoryNames: Set<String> = [
 ".git", ".svn", ".hg", ".jj", ".bzr", ".sl",
 "node_modules", "Pods", ".build", ".swiftpm", "DerivedData",
 ".next", ".nuxt", "dist", "build",
 ]

 // MARK: - Input

 private struct Input: Decodable {
 let pattern: String
 let path: String?
 }

 // MARK: - Execution

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let decoded: Input
 do {
 decoded = try JSONDecoder().decode(Input.self, from: input.json)
 } catch {
 return ToolResult(toolUseId: "", output: "Invalid input: \(error.localizedDescription)", isError: true)
 }

 let fm = FileManager.default

 // Resolve search root.
 let searchRoot: String
 if let explicit = decoded.path {
 searchRoot = FileReadTool.expandPath(explicit)
 } else {
 // Default: first authorized workspace folder, else memory dir.
 let workspaces = await context.services.fileProvider().authorizedFolders()
 if let first = workspaces.first {
 searchRoot = first.standardizedFileURL.path
 } else {
 searchRoot = MemoryStore.defaultRoot.standardizedFileURL.path
 }
 }

 if !(await FileReadTool.isPathAllowed(searchRoot, services: context.services)) {
 return ToolResult(toolUseId: "", output: "Access denied: search path is outside the authorized workspace and memory directory.", isError: true)
 }

 var isDir: ObjCBool = false
 guard fm.fileExists(atPath: searchRoot, isDirectory: &isDir), isDir.boolValue else {
 return ToolResult(toolUseId: "", output: "Path is not a directory: \(searchRoot)", isError: true)
 }

 // Compile glob → regex once.
 let regex: NSRegularExpression
 do {
 regex = try NSRegularExpression(pattern: Self.globToRegex(decoded.pattern))
 } catch {
 return ToolResult(toolUseId: "", output: "Invalid glob pattern: \(decoded.pattern)", isError: true)
 }

 let rootURL = URL(fileURLWithPath: searchRoot)
 var matches: [(path: String, mtime: Date)] = []
 var truncated = false

 if let enumerator = fm.enumerator(
 at: rootURL,
 includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
 options: [.skipsHiddenFiles]
 ) {
 while let item = enumerator.nextObject() as? URL {
 let components = item.pathComponents
 if components.contains(where: { Self.excludedDirectoryNames.contains($0) }) {
 if let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory == true {
 enumerator.skipDescendants()
 }
 continue
 }
 let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
 if values?.isDirectory == true { continue }

 // Match relative path against the regex.
 let relative = Self.relativePath(of: item.standardizedFileURL.path, under: searchRoot)
 let ns = relative as NSString
 let range = NSRange(location: 0, length: ns.length)
 if regex.firstMatch(in: relative, range: range) != nil {
 let mtime = values?.contentModificationDate ?? .distantPast
 matches.append((path: item.standardizedFileURL.path, mtime: mtime))
 if matches.count >= Self.maxResults {
 truncated = true
 break
 }
 }
 }
 }

 // Newest-first sort, tiebreak on filename.
 matches.sort { a, b in
 if a.mtime != b.mtime { return a.mtime > b.mtime }
 return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
 }

 if matches.isEmpty {
 return ToolResult(
 toolUseId: "",
 output: "No files matched \(decoded.pattern)",
 metadata: ["pattern": decoded.pattern, "path": searchRoot, "matches": "0"]
 )
 }

 var out = matches.map { $0.path }.joined(separator: "\n")
 if truncated {
 out += "\n(Results are truncated. Consider using a more specific path or pattern.)"
 }

 return ToolResult(
 toolUseId: "",
 output: out,
 metadata: [
 "pattern": decoded.pattern,
 "path": searchRoot,
 "matches": "\(matches.count)",
 "truncated": "\(truncated)"
 ]
 )
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .filesystem, operation: .search, summary: description)
 }

 // MARK: - Glob → regex

 /// Translate a shell-style glob into a `NSRegularExpression` pattern.
 /// Recognises `*` (non-slash), `**` (any incl. slash), `?` (single char),
 /// `[abc]` / `[!abc]` character classes. Everything else is escaped.
 /// Anchored with `^…$`.
 static func globToRegex(_ glob: String) -> String {
 var out = "^"
 let chars = Array(glob)
 var i = 0
 while i < chars.count {
 let c = chars[i]
 switch c {
 case "*":
 if i + 1 < chars.count && chars[i + 1] == "*" {
 out += ".*"
 i += 2
 // Consume an optional trailing slash on `**/`.
 if i < chars.count && chars[i] == "/" { i += 1 }
 } else {
 out += "[^/]*"
 i += 1
 }
 case "?":
 out += "[^/]"
 i += 1
 case "[":
 var cls = "["
 i += 1
 if i < chars.count && chars[i] == "!" {
 cls += "^"
 i += 1
 }
 while i < chars.count && chars[i] != "]" {
 cls.append(chars[i])
 i += 1
 }
 if i < chars.count { i += 1 }
 cls += "]"
 out += cls
 case ".", "(", ")", "+", "|", "^", "$", "{", "}", "\\":
 out += "\\\(c)"
 i += 1
 default:
 out.append(c)
 i += 1
 }
 }
 out += "$"
 return out
 }

 /// Return path relative to `root`, without a leading `/`.
 static func relativePath(of path: String, under root: String) -> String {
 let rootPrefix = root.hasSuffix("/") ? root : root + "/"
 if path == root { return "" }
 if path.hasPrefix(rootPrefix) { return String(path.dropFirst(rootPrefix.count)) }
 return path
 }
}
