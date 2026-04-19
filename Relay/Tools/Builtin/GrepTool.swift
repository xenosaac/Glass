import Foundation

///
/// Description is verbatim from `tools/GrepTool/prompt.ts:7-17` (the
/// `getDescription` function with `GREP_TOOL_NAME`, `BASH_TOOL_NAME`, and
/// `AGENT_TOOL_NAME` substituted). The "ALWAYS use Grep" / "NEVER invoke
/// grep or rg as a Bash command" lines are kept verbatim because the
/// model's training likely relies on them for tool selection.
///
/// Backend uses `NSRegularExpression` instead of ripgrep — iOS can't shell
/// out. All three output modes (`files_with_matches`, `content`, `count`)
/// and the usual flags (`-B`, `-A`, `-C`, `-n`, `-i`, `type`, `glob`,
/// `head_limit`, `offset`, `multiline`) are honored.
public struct GrepTool: RelayTool, Sendable {

 public var name: String { "Grep" }

 public var description: String {
 """
 A powerful search tool built on ripgrep

 Usage:
 - ALWAYS use Grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The Grep tool has been optimized for correct permissions and access.
 - Supports full regex syntax (e.g., "log.*Error", "function\\s+\\w+")
 - Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")
 - Output modes: "content" shows matching lines, "files_with_matches" shows only file paths (default), "count" shows match counts
 - Use Agent tool for open-ended searches requiring multiple rounds
 - Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping (use `interface\\{\\}` to find `interface{}` in Go code)
 - Multiline matching: By default patterns match within single lines only. For cross-line patterns like `struct \\{[\\s\\S]*?field`, use `multiline: true`
 """
 }

 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: """
 {
 "type": "object",
 "properties": {
 "pattern": { "type": "string", "description": "The regular expression pattern to search for in file contents" },
 "path": { "type": "string", "description": "File or directory to search in. Defaults to the first authorized workspace folder." },
 "glob": { "type": "string", "description": "Glob pattern to filter files (e.g. \\"*.js\\", \\"*.{ts,tsx}\\")" },
 "output_mode": { "type": "string", "enum": ["content", "files_with_matches", "count"], "description": "Output mode. Defaults to \\"files_with_matches\\"." },
 "-B": { "type": "integer", "description": "Number of lines to show before each match. Requires output_mode: \\"content\\"." },
 "-A": { "type": "integer", "description": "Number of lines to show after each match. Requires output_mode: \\"content\\"." },
 "-C": { "type": "integer", "description": "Alias for context." },
 "context": { "type": "integer", "description": "Number of lines to show before and after each match. Requires output_mode: \\"content\\"." },
 "-n": { "type": "boolean", "description": "Show line numbers in content mode. Defaults to true." },
 "-i": { "type": "boolean", "description": "Case insensitive search." },
 "type": { "type": "string", "description": "File type to search (js, py, rust, go, swift, ...). Shorthand for glob." },
 "head_limit": { "type": "integer", "description": "Limit output to first N lines/entries. Defaults to 250. Pass 0 for unlimited." },
 "offset": { "type": "integer", "description": "Skip first N lines/entries before applying head_limit. Defaults to 0." },
 "multiline": { "type": "boolean", "description": "Enable multiline mode where . matches newlines and patterns can span lines. Default: false." }
 },
 "required": ["pattern"]
 }
 """)
 }

 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }
 /// grep with a loose pattern can return hundreds
 /// of hits; cap at 5 KB so the wrapper's preview still gives the
 /// model 2 KB of matches to reason over.
 public var maxResultSizeChars: Int { 5_000 }

 public init() {}

 /// Default `head_limit` when unspecified. Matches CC.
 public static let defaultHeadLimit = 250

 /// Hard per-file byte cap. Files larger than this are skipped to keep
 /// search latency sane on device.
 public static let maxFileBytes = 2_097_152 // 2 MB

 /// `type` → extension list. Common entries match ripgrep's `--type`.
 public static let typeToExtensions: [String: [String]] = [
 "js": ["js", "jsx", "mjs", "cjs"],
 "ts": ["ts", "tsx"],
 "py": ["py"],
 "rust": ["rs"],
 "go": ["go"],
 "java": ["java"],
 "kotlin": ["kt", "kts"],
 "swift": ["swift"],
 "c": ["c", "h"],
 "cpp": ["cc", "cpp", "cxx", "h", "hpp"],
 "rb": ["rb"],
 "sh": ["sh", "bash", "zsh"],
 "md": ["md", "markdown"],
 "json": ["json"],
 "yaml": ["yml", "yaml"],
 ]

 // MARK: - Input

 private struct Input: Decodable {
 let pattern: String
 let path: String?
 let glob: String?
 let output_mode: String?
 let B: Int?
 let A: Int?
 let C: Int?
 let context: Int?
 let n: Bool?
 let i: Bool?
 let type: String?
 let head_limit: Int?
 let offset: Int?
 let multiline: Bool?

 enum CodingKeys: String, CodingKey {
 case pattern, path, glob, output_mode, context, type, head_limit, offset, multiline
 case B = "-B", A = "-A", C = "-C"
 case n = "-n", i = "-i"
 }
 }

 // MARK: - Execution

 public func call(input: ToolInput, context toolCtx: ToolCallContext) async throws -> ToolResult {
 let decoded: Input
 do {
 decoded = try JSONDecoder.decode(Input.self, from: input.json)
 } catch {
 return ToolResult(toolUseId: "", output: "Invalid input: \(error.localizedDescription)", isError: true)
 }

 let fm = FileManager.default

 // Resolve search root.
 let searchRoot: String
 if let explicit = decoded.path {
 searchRoot = FileReadTool.expandPath(explicit)
 } else {
 let workspaces = await toolCtx.services.fileProvider.authorizedFolders
 if let first = workspaces.first {
 searchRoot = first.standardizedFileURL.path
 } else {
 searchRoot = MemoryStore.defaultRoot.standardizedFileURL.path
 }
 }

 if !(await FileReadTool.isPathAllowed(searchRoot, services: toolCtx.services)) {
 return ToolResult(toolUseId: "", output: "Access denied: search path is outside the authorized workspace and memory directory.", isError: true)
 }

 var isDir: ObjCBool = false
 guard fm.fileExists(atPath: searchRoot, isDirectory: &isDir) else {
 return ToolResult(toolUseId: "", output: "Path does not exist: \(searchRoot)", isError: true)
 }

 // If search root is a file, restrict to that file.
 let isSingleFile = !isDir.boolValue

 // Compile content regex.
 var regexOptions: NSRegularExpression.Options = []
 if decoded.i == true { regexOptions.insert(.caseInsensitive) }
 if decoded.multiline == true { regexOptions.insert(.dotMatchesLineSeparators) }
 let contentRegex: NSRegularExpression
 do {
 contentRegex = try NSRegularExpression(pattern: decoded.pattern, options: regexOptions)
 } catch {
 return ToolResult(toolUseId: "", output: "Invalid regex: \(decoded.pattern) — \(error.localizedDescription)", isError: true)
 }

 // Compile optional glob filter.
 let globRegex: NSRegularExpression?
 if let g = decoded.glob {
 globRegex = try? NSRegularExpression(pattern: GlobTool.globToRegex(g))
 } else {
 globRegex = nil
 }
 let typeExtensions: Set<String>? = decoded.type.flatMap { Self.typeToExtensions[$0].map(Set.init()) }

 // Enumerate candidate files.
 let candidateFiles = isSingleFile
 ? [URL(fileURLWithPath: searchRoot)]
 : Self.enumerateCandidates(root: searchRoot, globRegex: globRegex, typeExtensions: typeExtensions)

 // Output mode.
 let mode = decoded.output_mode ?? "files_with_matches"
 let multiline = decoded.multiline == true

 // Search.
 var perFileMatches: [(path: String, count: Int, lines: [(lineNumber: Int, content: String)])] = []
 for url in candidateFiles {
 // Size gate.
 if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > Self.maxFileBytes {
 continue
 }
 guard let data = try? Data(contentsOf: url),
 let text = String(data: data, encoding: .utf8)
 else { continue }

 var fileCount = 0
 var lineHits: [(Int, String)] = []

 if multiline {
 let ns = text as NSString
 let matches = contentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
 fileCount = matches.count
 // In multiline mode, render match location as starting line; content is the whole matched substring truncated.
 for m in matches {
 let lineNum = Self.lineNumber(at: m.range.location, in: text)
 let matched = ns.substring(with: m.range)
 let single = matched.replacingOccurrences(of: "\n", with: "↵ ")
 lineHits.append((lineNum, single))
 }
 } else {
 let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
 for (idx, line) in lines.enumerated() {
 let str = String(line)
 let ns = str as NSString
 let matches = contentRegex.matches(in: str, range: NSRange(location: 0, length: ns.length))
 if !matches.isEmpty {
 fileCount += matches.count
 lineHits.append((idx + 1, str))
 }
 }
 }

 if fileCount > 0 {
 perFileMatches.append((path: url.standardizedFileURL.path, count: fileCount, lines: lineHits))
 }
 }

 // Sort newest first where file order matters.
 perFileMatches.sort { a, b in
 let fa = (try? URL(fileURLWithPath: a.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
 let fb = (try? URL(fileURLWithPath: b.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
 if fa != fb { return fa > fb }
 return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
 }

 let offset = max(decoded.offset ?? 0, 0)
 let rawHeadLimit = decoded.head_limit ?? Self.defaultHeadLimit
 let headLimit = rawHeadLimit == 0 ? Int.max : rawHeadLimit
 let showLineNumbers = decoded.n ?? true
 let context = decoded.context ?? decoded.C
 let before = decoded.B ?? context ?? 0
 let after = decoded.A ?? context ?? 0

 switch mode {
 case "files_with_matches":
 let files = perFileMatches.map { $0.path }
 let limited = Array(files.dropFirst(offset).prefix(headLimit))
 let header = "Found \(perFileMatches.count) file\(perFileMatches.count == 1 ? "" : "s")"
 let body = limited.joined(separator: "\n")
 let out = limited.isEmpty ? "No files matched \(decoded.pattern)" : header + "\n" + body
 return ToolResult(
 toolUseId: "",
 output: out,
 metadata: [
 "mode": "files_with_matches",
 "matches": "\(perFileMatches.count)"
 ]
 )

 case "count":
 let countLines = perFileMatches.map { "\($0.path):\($0.count)" }
 let limited = Array(countLines.dropFirst(offset).prefix(headLimit))
 let totalHits = perFileMatches.reduce(0) { $0 + $1.count }
 let footer = "Found \(totalHits) total occurrence\(totalHits == 1 ? "" : "s") across \(perFileMatches.count) file\(perFileMatches.count == 1 ? "" : "s")."
 let out = limited.isEmpty ? "No matches for \(decoded.pattern)" : limited.joined(separator: "\n") + "\n" + footer
 return ToolResult(
 toolUseId: "",
 output: out,
 metadata: ["mode": "count", "totalMatches": "\(totalHits)"]
 )

 case "content":
 var rendered: [String] = []
 for file in perFileMatches {
 // Re-split once per file to apply -B / -A context.
 let allLines: [String]
 if let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)),
 let text = String(data: data, encoding: .utf8) {
 allLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init())
 } else {
 allLines = []
 }
 var matchIndexes = Set(file.lines.map { $0.lineNumber })
 // Sort ascending for contextual output.
 let sortedHits = file.lines.sorted() { $0.lineNumber < $1.lineNumber }
 var previousLine: Int? = nil
 for hit in sortedHits {
 // Separator between non-contiguous windows.
 if let prev = previousLine, hit.lineNumber - prev > before + after + 1 {
 rendered.append("--")
 }
 let windowStart = max(1, hit.lineNumber - before)
 let windowEnd = min(allLines.count, hit.lineNumber + after)
 for ln in windowStart...windowEnd {
 let raw = ln - 1 < allLines.count ? allLines[ln - 1] : ""
 let marker = matchIndexes.contains(ln) ? ":" : "-"
 var line = "\(file.path)\(marker)"
 if showLineNumbers { line += "\(ln)\(marker)" }
 line += raw
 rendered.append(line)
 }
 previousLine = windowEnd
 }
 _ = matchIndexes
 }
 let limited = Array(rendered.dropFirst(offset).prefix(headLimit))
 let out = limited.isEmpty ? "No matches for \(decoded.pattern)" : limited.joined(separator: "\n")
 return ToolResult(
 toolUseId: "",
 output: out,
 metadata: ["mode": "content", "files": "\(perFileMatches.count)"]
 )

 default:
 return ToolResult(toolUseId: "", output: "Unknown output_mode: \(mode). Use content, files_with_matches, or count.", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .filesystem, operation: .search, summary: description)
 }

 // MARK: - Helpers

 private static func enumerateCandidates(
 root: String,
 globRegex: NSRegularExpression?,
 typeExtensions: Set<String>?
 ) -> [URL] {
 let fm = FileManager.default
 var out: [URL] = []
 guard let enumerator = fm.enumerator(
 at: URL(fileURLWithPath: root),
 includingPropertiesForKeys: [.isDirectoryKey],
 options: [.skipsHiddenFiles]
 ) else { return out }

 while let item = enumerator.nextObject as? URL {
 let components = item.pathComponents
 if components.contains(where: { GlobTool.excludedDirectoryNames.contains($0) }) {
 if let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory == true {
 enumerator.skipDescendants
 }
 continue
 }
 if let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory == true {
 continue
 }
 // Type filter.
 if let exts = typeExtensions {
 let ext = item.pathExtension.lowercased()
 if !exts.contains(ext) { continue }
 }
 // Glob filter on relative path.
 if let g = globRegex {
 let rel = GlobTool.relativePath(of: item.standardizedFileURL.path, under: root)
 let ns = rel as NSString
 if g.firstMatch(in: rel, range: NSRange(location: 0, length: ns.length)) == nil {
 continue
 }
 }
 out.append(item)
 }
 return out
 }

 /// Line number (1-indexed) for the character at `utf16Offset` in `text`.
 /// Used by multiline mode where match ranges are byte offsets.
 private static func lineNumber(at utf16Offset: Int, in text: String) -> Int {
 var line = 1
 var i = 0
 for ch in text.utf16 {
 if i >= utf16Offset { break }
 if ch == 10 { line += 1 }
 i += 1
 }
 return line
 }
}
