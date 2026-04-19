import Foundation

/// Write a memory file to the persistent on-device memory directory.
///
/// Replaces the old `MemoryRecallTool` / `MemoryStoreTool` pair. There is no
/// `memory_read` equivalent — the `MEMORY.md` index is pre-loaded into every
/// turn's system prompt, and topic files can be reached via a generic
/// file-read tool if the model needs the detail.
///
/// on the per-project memory dir (`memdir/memdir.ts`). We wrap it in a
/// focused tool so Gemma gets path-regex validation and a schema
/// description that steers it toward the right naming convention.
public struct MemoryWriteTool: RelayTool, Sendable {

 public var name: String { "memory_write" }

 public var description: String {
 """
 Write a memory file to the persistent on-device memory directory. Use this when the user asks you to remember something, or when you have learned something durable about them, their project, or their preferences.

 path: a relative filename. Allowed shapes:
 - `MEMORY.md` (the index — add one-line pointers here)
 - `user_<topic>.md`, `feedback_<topic>.md`, `project_<topic>.md`, `reference_<topic>.md`
 The `<topic>` portion is lowercase letters, digits, or underscores.

 content: the full file contents. Overwrites any existing file at that path. Topic files should begin with YAML frontmatter (name, description, type) followed by a markdown body. MEMORY.md is a plain markdown bullet list: `- [Title](file.md) — one-line hook`.

 After writing a topic file, call `memory_write` a second time to update MEMORY.md with a one-line pointer to it. When path=MEMORY.md, content MUST include every existing bullet plus the new one — the store rejects writes that drop entries, and the rejection error tells you which lines were missing so you can retry with the full set.
 """
 }

 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: """
 {
 "type": "object",
 "properties": {
 "path": { "type": "string", "description": "Relative filename inside the memory directory." },
 "content": { "type": "string", "description": "Full file contents (overwrites any existing file)." }
 },
 "required": ["path", "content"]
 }
 """)
 }

 public var isConcurrencySafe: Bool { false }
 public var isReadOnly: Bool { false }
 public var isDestructive: Bool { false }

 public init() {}

 private struct Input: Decodable {
 let path: String
 let content: String
 }

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let decoded: Input
 do {
 decoded = try JSONDecoder.decode(Input.self, from: input.json)
 } catch {
 return ToolResult(
 toolUseId: "",
 output: "Invalid input: \(error.localizedDescription)",
 isError: true
 )
 }

 guard let store = context.services.memoryStore else {
 return ToolResult(
 toolUseId: "",
 output: "Memory store is not available in this session.",
 isError: true
 )
 }

 do {
 try await store.writeFile(decoded.path, content: decoded.content)
 return ToolResult(
 toolUseId: "",
 output: "Wrote \(decoded.content.utf8.count) bytes to memory/\(decoded.path)."
 )
 } catch MemoryStore.MemoryError.invalidPath(let p) {
 return ToolResult(
 toolUseId: "",
 output: "Rejected path \"\(p)\": must be MEMORY.md or <type>_<topic>.md where type is user|feedback|project|reference.",
 isError: true
 )
 } catch MemoryStore.MemoryError.contentTooLarge(let bytes, let limit) {
 return ToolResult(
 toolUseId: "",
 output: "Content is \(bytes) bytes; memory files are capped at \(limit). Split it or summarize.",
 isError: true
 )
 } catch MemoryStore.MemoryError.indexDroppedEntries(let missing) {
 let joined = missing.joined(separator: ", ")
 return ToolResult(
 toolUseId: "",
 output: "MEMORY.md rewrite rejected: it must preserve every existing bullet. Re-issue the write with the full index plus your new line. Missing entries: \(joined).",
 isError: true
 )
 } catch {
 return ToolResult(
 toolUseId: "",
 output: "Write failed: \(error.localizedDescription)",
 isError: true
 )
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .reversible(domain: .memory, operation: .write, summary: description)
 }
}
