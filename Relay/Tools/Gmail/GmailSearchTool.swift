import Foundation

/// Search Gmail messages with Gmail's advanced query syntax.
public struct GmailSearchTool: RelayTool, Sendable {
 public var name: String { "gmail_search" }
 public var description: String {
 "Search Gmail messages. Supports Gmail query syntax (e.g., 'from:alice subject:invoice newer_than:7d'). Returns a list of message summaries."
 }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"""
 {
 "type": "object",
 "properties": {
 "query": {
 "type": "string",
 "description": "Gmail search query (e.g., 'from:alice', 'in:inbox newer_than:7d', 'has:attachment')"
 },
 "max_results": {
 "type": "integer",
 "description": "Maximum number of results to return (default 10, max 25)"
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
 return ToolResult(toolUseId: "", output: "Error: 'query' is required", isError: true)
 }
 let maxResults = (params["max_results"] as? Int) ?? 10

 let gmail = context.services.gmail
 guard await gmail().isSignedIn() else {
 return ToolResult(
 toolUseId: "",
 output: "Error: Not signed in to Gmail. Connect your account in Settings → Gmail.",
 isError: true
 )
 }

 do {
 let results = try await gmail().search(query: query, maxResults: maxResults)
 if results.isEmpty {
 return ToolResult(toolUseId: "", output: "No messages found for query: \(query)")
 }
 var lines = ["Found \(results.count) message(s) for query: \(query)"]
 for (i, m) in results.enumerated() {
 lines.append("")
 lines.append("\(i + 1). From: \(m.from)")
 lines.append(" Subject: \(m.subject)")
 lines.append(" Date: \(m.date)")
 lines.append(" ID: \(m.id) Thread: \(m.threadId)")
 if !m.snippet.isEmpty {
 lines.append(" Snippet: \(m.snippet)")
 }
 }
 return ToolResult(toolUseId: "", output: lines.joined(separator: "\n"))
 } catch {
 return ToolResult(toolUseId: "", output: "Error: \(error.localizedDescription)", isError: true)
 }
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .gmail, operation: .search, summary: description)
 }
}
