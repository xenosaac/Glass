import Foundation

///
/// Description is adapted verbatim from `tools/FileReadTool/prompt.ts`
/// (`renderPromptTemplate` with CC's default line-format + targeted offset
/// instruction, stripped of PDF / Jupyter / image / screenshot lines that
/// don't apply to the iOS sandbox). Line numbering, offset/limit defaults,
/// and empty-file reminder all follow CC's behavior.
///
/// Permission: path must be inside either an authorized workspace folder
/// (via `FileProvider`) or the on-device memory directory
/// (`MemoryStore.defaultRoot`). Anything else is denied.
public struct FileReadTool: RelayTool, Sendable {

 public var name: String { "Read" }

 public var description: String {
 // Verbatim-where-applicable port of renderPromptTemplate at
 // tools/FileReadTool/prompt.ts:32-48.
 """
 Reads a file from the local filesystem. You can access any file directly by using this tool.
 Assume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid. It is okay to read a file that does not exist; an error will be returned.

 Usage:
 - The file_path parameter must be an absolute path, not a relative path
 - By default, it reads up to 2000 lines starting from the beginning of the file
 - When you already know which part of the file you need, only read that part. This can be important for larger files.
 - Results are returned using cat -n format, with line numbers starting at 1
 - This tool can only read files, not directories.
 - If you read a file that exists but has empty contents you will receive a system reminder warning in place of file contents.
 """
 }

 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: """
 {
 "type": "object",
 "properties": {
 "file_path": {
 "type": "string",
 "description": "The absolute path to the file to read"
 },
 "offset": {
 "type": "integer",
 "minimum": 0,
 "description": "The line number to start reading from. Only provide if the file is too large to read at once."
 },
 "limit": {
 "type": "integer",
 "minimum": 1,
 "description": "The number of lines to read. Only provide if the file is too large to read at once."
 }
 },
 "required": ["file_path"]
 }
 """)
 }

 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }
 /// FileRead already self-caps at
 /// `maxOutputCharacters = 80_000` (line 79) and can be re-read via
 /// offset+limit. Set the boundary cap to match so the persistor
 /// layer is only a safety net for pathological files.
 public var maxResultSizeChars: Int { Self.maxOutputCharacters }

 public init() {}

 // MARK: - Constants (ported from tools/FileReadTool/prompt.ts + limits.ts)

 /// Default cap on lines returned when no `limit` is provided. CC's
 /// `MAX_LINES_TO_READ` at `tools/FileReadTool/prompt.ts:10`.
 public static let defaultMaxLines = 2000

 /// Hard byte cap beyond which the tool requires explicit offset/limit.
 /// Matches the 256 KB cap used by CC's default file-size instruction.
 public static let maxFileBytesWithoutLimit = 262_144

 /// Per-read character cap to keep tool_result from blowing up context.
 /// Conservative — CC applies a token estimate; we use char count as a
 /// rough proxy (~4 chars/token). 80K chars ≈ 20K tokens.
 public static let maxOutputCharacters = 80_000

 // MARK: - Input

 private struct Input: Decodable {
 let file_path: String
 let offset: Int?
 let limit: Int?
 }

 // MARK: - Execution

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let decoded: Input
 do {
 decoded = try JSONDecoder().decode(Input.self, from: input.json)
 } catch {
 return errorResult("Invalid input: \(error.localizedDescription)")
 }

 let expanded = Self.expandPath(decoded.file_path)

 // Permission gate. Memory directory is always allowed; workspace
 // paths go through FileProvider's authorization check.
 if !(await Self.isPathAllowed(expanded, services: context.services)) {
 return errorResult("Access denied: path is outside the authorized workspace and memory directory.")
 }

 let fm = FileManager.default
 var isDir: ObjCBool = false
 guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else {
 return errorResult("File does not exist: \(expanded)")
 }
 if isDir.boolValue {
 return errorResult("This tool can only read files, not directories: \(expanded)")
 }

 // Size check — require offset/limit for files over the cap.
 let attrs = try? fm.attributesOfItem(atPath: expanded)
 let size = (attrs?[.size] as? Int) ?? 0
 if decoded.limit == nil && size > Self.maxFileBytesWithoutLimit {
 return errorResult("File exceeds \(Self.maxFileBytesWithoutLimit / 1024)KB. Use offset and limit parameters.")
 }

 // Binary detection: NUL byte in the first 512 bytes → refuse.
 // 2 : explicitly close the FileHandle so
 // the FD is released promptly. ARC eventually deallocates it,
 // but a heavily-tooled session reading hundreds of files could
 // briefly accumulate FD pressure.
 do {
 let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: expanded))
 defer { try? handle.close }
 if let head = try handle.read(upToCount: 512), head.contains(0) {
 return errorResult("Cannot read binary file: \(expanded)")
 }
 } catch {
 // Failure to peek isn't fatal — fall through to the full read
 // below, which will surface a friendlier "Read failed" error
 // if the file is genuinely unreadable.
 }

 // Read + decode.
 let data: Data
 do {
 data = try Data(contentsOf: URL(fileURLWithPath: expanded))
 } catch {
 return errorResult("Read failed: \(error.localizedDescription)")
 }
 guard let content = String(data: data, encoding: .utf8) else {
 return errorResult("File is not valid UTF-8: \(expanded)")
 }

 // Empty-file system reminder. Matches the last bullet of CC's prompt.
 if content.isEmpty {
 return ToolResult(
 toolUseId: "",
 output: "<system-reminder>\nFile exists but is empty.\n</system-reminder>"
 )
 }

 // Split into lines preserving empty trailing line for fidelity.
 // `split(..., omittingEmptySubsequences: false)` keeps blank lines
 // and a trailing newline as an empty element.
 let allLines = content.split(separator: "\n", omittingEmptySubsequences: false)

 let offsetIn = max(decoded.offset ?? 1, 1)
 let startIdx = offsetIn - 1
 if startIdx >= allLines.count {
 return errorResult("Offset \(offsetIn) is past the end of file (\(allLines.count) lines).")
 }
 let remaining = allLines.count - startIdx
 let take = min(decoded.limit ?? Self.defaultMaxLines, remaining)
 let slice = allLines[startIdx..<(startIdx + take)]

 // cat -n format: `<line>\t<content>`, line numbers absolute from offset.
 var out = ""
 out.reserveCapacity(take * 40)
 for (i, line) in slice.enumerated() {
 out += "\(offsetIn + i)\t\(line)\n"
 }

 if out.count > Self.maxOutputCharacters {
 let truncIndex = out.index(out.startIndex, offsetBy: Self.maxOutputCharacters)
 out = String(out[..<truncIndex]) + "\n[Output truncated at \(Self.maxOutputCharacters) characters. Read a narrower range with offset+limit.]"
 }

 return ToolResult(
 toolUseId: "",
 output: out,
 metadata: [
 "path": expanded,
 "startLine": "\(offsetIn)",
 "linesReturned": "\(take)",
 "totalLines": "\(allLines.count)"
 ]
 )
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .filesystem, operation: .read, summary: description)
 }

 // MARK: - Helpers

 private func errorResult(_ message: String) -> ToolResult {
 ToolResult(toolUseId: "", output: message, isError: true)
 }

 /// Expand `~` and normalise backslashes. Mirrors CC's `expandPath` at
 /// `utils/path.ts`. iOS has no per-user home, so `~` expands to the
 /// app's sandbox home via `NSHomeDirectory`; `FileProvider` scope
 /// rejects anything outside the authorized folders anyway.
 static func expandPath(_ path: String) -> String {
 var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
 if p.hasPrefix("~") {
 p = NSHomeDirectory() + String(p.dropFirst())
 }
 return p.replacingOccurrences(of: "\\", with: "/")
 }

 /// A path is allowed when it falls inside an authorized workspace folder
 /// OR the on-device memory directory. Both gates use path-prefix matching
 /// rather than symlink resolution so we never follow a symlink out of
 /// scope.
 static func isPathAllowed(_ path: String, services: any ServiceLocator) async -> Bool {
 // Memory dir — always allowed, all tools.
 let memoryPath = MemoryStore.defaultRoot.standardizedFileURL.path
 let memPrefix = memoryPath.hasSuffix("/") ? memoryPath : memoryPath + "/"
 if path == memoryPath || path.hasPrefix(memPrefix) { return true }

 // Workspace — via FileProvider's authorization check.
 return await services.fileProvider().isAuthorized(path: path)
 }
}
