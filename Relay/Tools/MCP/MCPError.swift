import Foundation

/// Errors that can occur during MCP operations.
public enum MCPError: Error, LocalizedError, Sendable {
 /// Network request failed
 case networkError(String)

 /// Server returned JSON-RPC error
 case serverError(code: Int, message: String)

 /// Server returned an HTTP status failure before JSON-RPC parsing
 case httpStatus(code: Int, body: String, contentType: String?)

 /// Server returned a JSON-RPC error envelope
 case jsonRPCError(code: Int, message: String)

 /// Server returned a content type this client does not yet support
 case unsupportedContentType(String)

 /// Invalid or unparseable response
 case invalidResponse(String)

 /// Request timed out
 case timeout(server: String)

 /// Tool not found on server
 case toolNotFound(name: String, server: String)

 /// Server not configured
 case serverNotConfigured(String)

 /// MCP not enabled
 case disabled

 public var errorDescription: String? {
 switch self {
 case .networkError(let msg):
 return "Network error: \(msg)"
 case .serverError(let code, let msg):
 return "MCP server error (\(code)): \(msg)"
 case .httpStatus(let code, let body, _):
 return "HTTP \(code): \(body)"
 case .jsonRPCError(let code, let msg):
 return "MCP JSON-RPC error (\(code)): \(msg)"
 case .unsupportedContentType(let type):
 return "Unsupported MCP content type: \(type)"
 case .invalidResponse(let details):
 return "Invalid MCP response: \(details)"
 case .timeout(let server):
 return "Request to \(server) timed out"
 case .toolNotFound(let name, let server):
 return "Tool '\(name)' not found on server '\(server)'"
 case .serverNotConfigured(let name):
 return "MCP server '\(name)' is not configured"
 case .disabled:
 return "MCP is disabled"
 }
 }
}
