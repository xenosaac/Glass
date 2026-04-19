import Foundation

/// Manages connection to a single MCP server.
///
/// Handles hosted-MCP initialization, tool discovery with caching, and tool
/// execution via JSON-RPC over Streamable HTTP.
public actor MCPClient: MCPClientService {
 private struct InitializationState: Sendable {
 let sessionID: String?
 let protocolVersion: String
 let serverName: String?
 }

 private enum ServerKind {
 case canvas
 case generic
 }

 private static let supportedProtocolVersion = "2025-06-18"

 private let config: MCPServerConfig
 private let transport: HTTPTransport

 // Initialization state
 private var hasCompletedInitialization = false
 private var sessionID: String?
 private var negotiatedProtocolVersion: String?
 private var initializedServerName: String?
 private var initializeTask: Task<InitializationState, Error>?

 // Tool cache
 private var cachedTools: [MCPToolDefinition]?
 private var cacheExpiry: Date?
 private let cacheTTL: TimeInterval = 300 // 5 minutes

 public init(config: MCPServerConfig, session: URLSession = .shared) {
 self.config = config
 self.transport = HTTPTransport(
 baseURL: config.baseURL,
 session: session,
 timeout: config.timeout,
 headers: config.headers
 )
 }

 /// The server's display name.
 public nonisolated var serverName: String { config.name }

 /// The server's safe name for tool namespacing.
 public nonisolated var safeName: String { config.safeName }

 // MARK: - MCPClientService

 /// List tools from the server. Uses cache if fresh.
 public func listTools(forceRefresh: Bool = false) async throws -> [MCPToolDefinition] {
 if !forceRefresh,
 let cached = cachedTools,
 let expiry = cacheExpiry,
 Date() < expiry {
 log("listTools cache hit count=\(cached.count)")
 return cached
 }

 log("listTools start forceRefresh=\(forceRefresh)")
 _ = try await initializeIfNeeded

 let request = JSONRPCRequest(method: "tools/list")
 let result: MCPToolsListResult = try await transport.send(
 request: request,
 responseType: MCPToolsListResult.self
 )

 cachedTools = result.tools
 cacheExpiry = Date().addingTimeInterval(cacheTTL)
 log("listTools success count=\(result.tools.count)")
 return result.tools
 }

 /// Call a tool on the server.
 public func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolCallResult {
 log("callTool start name=\(name) argumentKeys=\(arguments.keys.sorted())")
 _ = try await initializeIfNeeded

 let params: [String: AnyCodable] = [
 "name": AnyCodable(name),
 "arguments": AnyCodable(arguments)
 ]

 let request = JSONRPCRequest(method: "tools/call", params: params)
 let result: MCPToolCallResult = try await transport.send(
 request: request,
 responseType: MCPToolCallResult.self
 )
 log("callTool success name=\(name) blocks=\(result.content.count) isError=\(result.isError ?? false)")
 return result
 }

 // MARK: - Resources (optional MCP feature)

 /// List resources from the server.
 public func listResources() async throws -> [MCPResourceDefinition] {
 log("listResources start")
 _ = try await initializeIfNeeded

 let request = JSONRPCRequest(method: "resources/list")
 let result: MCPResourcesListResult = try await transport.send(
 request: request,
 responseType: MCPResourcesListResult.self
 )

 log("listResources success count=\(result.resources.count)")
 return result.resources
 }

 /// Read a resource by URI.
 public func readResource(uri: String) async throws -> MCPContentBlock {
 log("readResource start uri=\(uri)")
 _ = try await initializeIfNeeded

 let params: [String: AnyCodable] = ["uri": AnyCodable(uri)]
 let request = JSONRPCRequest(method: "resources/read", params: params)

 struct ReadResult: Codable {
 let contents: [MCPContentBlock]
 }

 let result: ReadResult = try await transport.send(
 request: request,
 responseType: ReadResult.self
 )

 guard let content = result.contents.first else {
 throw MCPError.invalidResponse("Resource read returned no content")
 }
 log("readResource success uri=\(uri) type=\(content.type)")
 return content
 }

 // MARK: - Diagnostics

 func runConnectionDiagnostics(forceRefresh: Bool = true) async -> MCPConnectionReport {
 log("diagnostics start forceRefresh=\(forceRefresh)")
 let checkedAt = Date()
 var diagnostics = MCPConnectionPhase.allCases.map(MCPConnectionDiagnostic.skipped)

 do {
 let state = try await initializeIfNeeded(forceRefresh: forceRefresh)
 diagnostics[index(of: .reachability)] = .success(.reachability, message: "Server reachable")
 diagnostics[index(of: .protocolCompatibility)] = .success(.protocolCompatibility, message: "Server speaks MCP")
 let initializeMessage = state.serverName.map { "Authenticated as \($0)" } ?? "Session initialized"
 diagnostics[index(of: .initialize)] = .success(.initialize, message: initializeMessage)

 do {
 let tools = try await listTools(forceRefresh: true)
 let names = Array(tools.prefix(5).map(\.name))
 if tools.isEmpty {
 let failure = MCPConnectionFailure(
 category: .zeroTools,
 headline: "Healthy, but reports zero tools",
 detail: nil,
 remediation: remediation(for: .zeroTools)
 )
 diagnostics[index(of: .discovery)] = .warning(.discovery,
 message: failure.headline,
 failure: failure)
 } else {
 diagnostics[index(of: .discovery)] = .success(.discovery, message: "\(tools.count) tools available")
 }

 let report = MCPConnectionReport(
 diagnostics: diagnostics,
 toolCount: tools.count,
 toolNames: names,
 errorMessage: tools.isEmpty ? "Healthy, but reports zero tools" : nil,
 checkedAt: checkedAt,
 negotiatedProtocolVersion: state.protocolVersion
 )
 log("diagnostics complete summary=\(diagnosticSummary(report.diagnostics))")
 return report
 } catch {
 let failure = classifyDiscoveryError(error)
 diagnostics[index(of: .discovery)] = .failure(.discovery, failure: failure)
 let report = MCPConnectionReport(
 diagnostics: diagnostics,
 toolCount: nil,
 toolNames: [],
 errorMessage: failure.headline,
 checkedAt: checkedAt,
 negotiatedProtocolVersion: state.protocolVersion
 )
 log("diagnostics discovery failure category=\(failure.category.rawValue) summary=\(diagnosticSummary(report.diagnostics))")
 return report
 }
 } catch {
 let classification = classifyInitializeError(error)
 for phase in classification.passedPhases {
 diagnostics[index(of: phase)] = successDiagnostic(for: phase)
 }
 diagnostics[index(of: classification.failedPhase)] = .failure(classification.failedPhase, failure: classification.failure)

 let report = MCPConnectionReport(
 diagnostics: diagnostics,
 toolCount: nil,
 toolNames: [],
 errorMessage: classification.failure.headline,
 checkedAt: checkedAt,
 negotiatedProtocolVersion: negotiatedProtocolVersion
 )
 log("diagnostics initialize failure category=\(classification.failure.category.rawValue) summary=\(diagnosticSummary(report.diagnostics))")
 return report
 }
 }

 // MARK: - Cache Management

 /// Invalidate the tool cache, forcing refresh on next listTools call.
 public func invalidateCache() {
 cachedTools = nil
 cacheExpiry = nil
 }

 // MARK: - Initialization

 func initializeIfNeeded(forceRefresh: Bool = false) async throws -> (sessionID: String?, protocolVersion: String, serverName: String?) {
 let state = try await performInitialization(forceRefresh: forceRefresh)
 return (state.sessionID, state.protocolVersion, state.serverName)
 }

 private func performInitialization(forceRefresh: Bool) async throws -> InitializationState {
 if forceRefresh {
 log("initialize reset requested")
 await resetInitializationState()
 }

 if hasCompletedInitialization,
 let protocolVersion = negotiatedProtocolVersion {
 log("initialize reuse session session=\(sessionID == nil ? "absent" : "present") protocol=\(protocolVersion)")
 return InitializationState(sessionID: sessionID,
 protocolVersion: protocolVersion,
 serverName: initializedServerName)
 }

 if let initializeTask {
 log("initialize awaiting in-flight task")
 return try await initializeTask.value
 }

 log("initialize start protocol=\(Self.supportedProtocolVersion)")
 let task = Task<InitializationState, Error> { [config, transport] in
 Self.log(server: config.safeName, "initialize request start")
 let request = JSONRPCRequest(method: "initialize", params: Self.initializeParams())
 let response: HTTPTransportResponse<MCPInitializeResult> = try await transport.sendWithMetadata(
 request: request,
 responseType: MCPInitializeResult.self
 )

 let protocolVersion = response.result.protocolVersion
 let sessionID = response.metadata.headerValue(named: "Mcp-Session-Id")

 await transport.setSessionID(sessionID)
 await transport.setProtocolVersion(protocolVersion)

 Self.log(
 server: config.safeName,
 "initialize response success server=\(response.result.serverInfo.name) protocol=\(protocolVersion) session=\(sessionID == nil ? "absent" : "present")"
 )
 try await transport.sendNotification(request: .notification(method: "notifications/initialized"))
 Self.log(server: config.safeName, "initialized notification sent")

 return InitializationState(sessionID: sessionID,
 protocolVersion: protocolVersion,
 serverName: response.result.serverInfo.name)
 }

 initializeTask = task

 do {
 let state = try await task.value
 hasCompletedInitialization = true
 sessionID = state.sessionID
 negotiatedProtocolVersion = state.protocolVersion
 initializedServerName = state.serverName
 initializeTask = nil
 log("initialize complete server=\(state.serverName ?? "-") session=\(state.sessionID == nil ? "absent" : "present") protocol=\(state.protocolVersion)")
 return state
 } catch {
 initializeTask = nil
 log("initialize failed error=\(error.localizedDescription)")
 throw error
 }
 }

 private func resetInitializationState() async {
 log("initialize state cleared")
 hasCompletedInitialization = false
 sessionID = nil
 negotiatedProtocolVersion = nil
 initializedServerName = nil
 initializeTask = nil
 invalidateCache()
 await transport.clearSessionState()
 }

 private nonisolated static func initializeParams() -> [String: AnyCodable] {
 let clientInfo: [String: AnyCodable] = [
 "name": AnyCodable("Glass"),
 "version": AnyCodable(clientVersion)
 ]

 return [
 "protocolVersion": AnyCodable(supportedProtocolVersion),
 "capabilities": AnyCodable([String: Any]()),
 "clientInfo": AnyCodable(clientInfo.mapValues(\.value))
 ]
 }

 private nonisolated static var clientVersion: String {
 let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
 let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

 switch (short, build) {
 case let (short?, build?) where !short.isEmpty && !build.isEmpty:
 return "\(short) (\(build))"
 case let (short?, _):
 return short
 case let (_, build?) where !build.isEmpty:
 return build
 default:
 return "dev"
 }
 }

 // MARK: - Diagnostic Classification

 private struct DiagnosticClassification {
 let passedPhases: [MCPConnectionPhase]
 let failedPhase: MCPConnectionPhase
 let failure: MCPConnectionFailure
 }

 private func classifyInitializeError(_ error: Error) -> DiagnosticClassification {
 guard let mcpError = error as? MCPError else {
 return DiagnosticClassification(
 passedPhases: [],
 failedPhase: .reachability,
 failure: MCPConnectionFailure(
 category: .network,
 headline: "Can't reach server",
 detail: error.localizedDescription,
 remediation: "Check the URL and your network, then try again."
 )
 )
 }

 switch mcpError {
 case .timeout:
 return DiagnosticClassification(
 passedPhases: [],
 failedPhase: .reachability,
 failure: MCPConnectionFailure(
 category: .timeout,
 headline: "Connection timed out",
 detail: mcpError.localizedDescription,
 remediation: "Check the URL and try again on a stable network."
 )
 )

 case .networkError(let message):
 let category: MCPConnectionFailureCategory = isTLSMessage(message) ? .tls : .network
 let headline = isTLSMessage(message) ? "TLS handshake failed" : "Can't reach server"
 let remediation = isTLSMessage(message)
 ? "Check the server certificate and make sure the endpoint supports HTTPS."
 : "Check the URL spelling and your network, then try again."
 return DiagnosticClassification(
 passedPhases: [],
 failedPhase: .reachability,
 failure: MCPConnectionFailure(
 category: category,
 headline: headline,
 detail: message,
 remediation: remediation
 )
 )

 case .httpStatus(let code, let body, _):
 if code == 401 || code == 403 || isAuthMessage(body) {
 return DiagnosticClassification(
 passedPhases: [.reachability, .protocolCompatibility],
 failedPhase: .initialize,
 failure: MCPConnectionFailure(
 category: .authRejected,
 headline: "Token rejected",
 detail: body,
 remediation: remediation(for: .authRejected)
 )
 )
 }
 if code == 406 || body.lowercased().contains("accept") {
 return DiagnosticClassification(
 passedPhases: [.reachability],
 failedPhase: .protocolCompatibility,
 failure: MCPConnectionFailure(
 category: .acceptRejected,
 headline: "Server rejected Accept header",
 detail: body,
 remediation: "This is a regression in Glass's HTTP transport. Capture the server response and fix the client."
 )
 )
 }
 return DiagnosticClassification(
 passedPhases: [.reachability],
 failedPhase: .protocolCompatibility,
 failure: MCPConnectionFailure(
 category: .httpStatus,
 headline: "Server returned HTTP \(code)",
 detail: body,
 remediation: code >= 500
 ? "The server failed before initialization completed. Try again later."
 : "Check the endpoint configuration and required headers."
 )
 )

 case .unsupportedContentType(let contentType):
 let isSSE = contentType.lowercased().contains("text/event-stream")
 return DiagnosticClassification(
 passedPhases: [.reachability],
 failedPhase: .protocolCompatibility,
 failure: MCPConnectionFailure(
 category: isSSE ? .sseUnsupportedYet : .malformedResponse,
 headline: isSSE ? "Server uses streaming responses Glass can't read yet" : "Unexpected response format",
 detail: contentType,
 remediation: isSSE
 ? "This hosted server returned SSE for initialize. SSE parsing is still pending."
 : "The server returned a non-JSON response. Verify the endpoint is an MCP Streamable HTTP server."
 )
 )

 case .jsonRPCError(let code, let message):
 if isAuthMessage(message) {
 return DiagnosticClassification(
 passedPhases: [.reachability, .protocolCompatibility],
 failedPhase: .initialize,
 failure: MCPConnectionFailure(
 category: .authRejected,
 headline: "Token rejected",
 detail: "JSON-RPC \(code): \(message)",
 remediation: remediation(for: .authRejected)
 )
 )
 }
 if isProtocolVersionMessage(message) {
 return DiagnosticClassification(
 passedPhases: [.reachability, .protocolCompatibility],
 failedPhase: .initialize,
 failure: MCPConnectionFailure(
 category: .protocolVersionMismatch,
 headline: "Server requires a different protocol version",
 detail: "JSON-RPC \(code): \(message)",
 remediation: "This server rejected the requested MCP protocol version. Retry after protocol-version tuning."
 )
 )
 }
 return DiagnosticClassification(
 passedPhases: [.reachability, .protocolCompatibility],
 failedPhase: .initialize,
 failure: MCPConnectionFailure(
 category: .jsonRPCError,
 headline: "Server returned an initialize error",
 detail: "JSON-RPC \(code): \(message)",
 remediation: "Check the server logs and required auth or protocol headers."
 )
 )

 case .invalidResponse(let details):
 return DiagnosticClassification(
 passedPhases: [.reachability, .protocolCompatibility],
 failedPhase: .initialize,
 failure: MCPConnectionFailure(
 category: .malformedResponse,
 headline: "Server returned data Glass couldn't parse",
 detail: details,
 remediation: "Capture the response details and compare them with the MCP initialize spec."
 )
 )

 case .serverError(let code, let message):
 return DiagnosticClassification(
 passedPhases: [.reachability, .protocolCompatibility],
 failedPhase: .initialize,
 failure: MCPConnectionFailure(
 category: .jsonRPCError,
 headline: "Server returned an initialize error",
 detail: "Legacy error \(code): \(message)",
 remediation: "Check the server response and update the MCP client classification if needed."
 )
 )

 case .toolNotFound, .serverNotConfigured, .disabled:
 return DiagnosticClassification(
 passedPhases: [],
 failedPhase: .reachability,
 failure: MCPConnectionFailure(
 category: .network,
 headline: "Client configuration error",
 detail: mcpError.localizedDescription,
 remediation: "Verify the configured server before retrying."
 )
 )
 }
 }

 private func classifyDiscoveryError(_ error: Error) -> MCPConnectionFailure {
 guard let mcpError = error as? MCPError else {
 return MCPConnectionFailure(
 category: .jsonRPCError,
 headline: "Discovery failed",
 detail: error.localizedDescription,
 remediation: "Retry Test Connection and inspect the server logs."
 )
 }

 switch mcpError {
 case .httpStatus(let code, let body, _):
 if body.lowercased().contains("session id") {
 return MCPConnectionFailure(
 category: .missingSessionID,
 headline: "Server rejected the session bootstrap",
 detail: body,
 remediation: "Initialize succeeded, but the server still rejected the session on tools/list. Capture the response and compare the returned session header."
 )
 }
 if code == 401 || code == 403 || isAuthMessage(body) {
 return MCPConnectionFailure(
 category: .authRejected,
 headline: "Token rejected during discovery",
 detail: body,
 remediation: remediation(for: .authRejected)
 )
 }
 return MCPConnectionFailure(
 category: .httpStatus,
 headline: "Discovery returned HTTP \(code)",
 detail: body,
 remediation: "The server failed after initialization. Verify the server's tools/list implementation."
 )

 case .unsupportedContentType(let contentType):
 let isSSE = contentType.lowercased().contains("text/event-stream")
 return MCPConnectionFailure(
 category: isSSE ? .sseUnsupportedYet : .malformedResponse,
 headline: isSSE ? "Discovery returned an SSE stream" : "Discovery returned a non-JSON response",
 detail: contentType,
 remediation: isSSE
 ? " SSE parsing is still pending for hosted MCP responses."
 : "Verify that tools/list returns JSON-RPC over application/json."
 )

 case .jsonRPCError(let code, let message):
 return MCPConnectionFailure(
 category: .jsonRPCError,
 headline: "Server returned a tools/list error",
 detail: "JSON-RPC \(code): \(message)",
 remediation: "The server initialized but rejected discovery. Check tool-discovery scopes or server logs."
 )

 case .invalidResponse(let details):
 return MCPConnectionFailure(
 category: .malformedResponse,
 headline: "Server returned malformed discovery data",
 detail: details,
 remediation: "Capture the tools/list response and compare it with the MCP tools schema."
 )

 case .timeout:
 return MCPConnectionFailure(
 category: .timeout,
 headline: "Discovery timed out",
 detail: mcpError.localizedDescription,
 remediation: "The session initialized, but tools/list timed out. Retry on a stable network."
 )

 case .networkError(let message):
 return MCPConnectionFailure(
 category: .network,
 headline: "Network error during discovery",
 detail: message,
 remediation: "The session initialized, but the network dropped during tools/list."
 )

 case .serverError(let code, let message):
 return MCPConnectionFailure(
 category: .jsonRPCError,
 headline: "Server returned a discovery error",
 detail: "Legacy error \(code): \(message)",
 remediation: "Check the server response and update the MCP client classification if needed."
 )

 case .toolNotFound, .serverNotConfigured, .disabled:
 return MCPConnectionFailure(
 category: .jsonRPCError,
 headline: "Discovery failed",
 detail: mcpError.localizedDescription,
 remediation: "Verify the server configuration and retry."
 )
 }
 }

 private func successDiagnostic(for phase: MCPConnectionPhase) -> MCPConnectionDiagnostic {
 switch phase {
 case .reachability:
 return .success(.reachability, message: "Server reachable")
 case .protocolCompatibility:
 return .success(.protocolCompatibility, message: "Server speaks MCP")
 case .initialize:
 return .success(.initialize,
 message: initializedServerName.map { "Authenticated as \($0)" } ?? "Session initialized")
 case .discovery:
 return .success(.discovery, message: "Discovery complete")
 }
 }

 private func index(of phase: MCPConnectionPhase) -> Int {
 MCPConnectionPhase.allCases.firstIndex(of: phase) ?? 0
 }

 private func remediation(for category: MCPConnectionFailureCategory) -> String {
 switch (serverKind, category) {
 case (.canvas, .authRejected):
 return "Regenerate a Canvas token in Canvas → Account → Settings → New Access Token, then paste it into X-Canvas-Token."
 case (.canvas, .zeroTools):
 return "Canvas initialized successfully but returned zero tools. Double-check the Canvas domain and token scopes."
 case (_, .zeroTools):
 return "The server initialized cleanly but reported zero tools. Check whether your token has discovery scope."
 case (_, .authRejected):
 return "Verify the server credentials and required scopes, then try Test Connection again."
 default:
 return "Fix the failing phase and retry Test Connection."
 }
 }

 private func diagnosticSummary(_ diagnostics: [MCPConnectionDiagnostic]) -> String {
 diagnostics.map { "\($0.phase.rawValue)=\(stateLabel($0.state))" }.joined(separator: ",")
 }

 private func stateLabel(_ state: MCPConnectionPhaseState) -> String {
 switch state {
 case .success:
 return "success"
 case .warning:
 return "warning"
 case .failure:
 return "failure"
 case .skipped:
 return "skipped"
 }
 }

 private func log(_ message: String) {
 Self.log(server: config.safeName, message)
 }

 private nonisolated static func log(server: String, _ message: String) {
 print("[MCP][\(server)] \(message)")
 }

 private var serverKind: ServerKind {
 let headerKeys = Set(config.headers.keys.map { $0.lowercased() })
 if headerKeys.contains("x-canvas-token") || headerKeys.contains("x-canvas-url") || config.baseURL.host == "mcp.illinihunt.org" {
 return .canvas
 }
 return .generic
 }

 private func isAuthMessage(_ message: String) -> Bool {
 let lower = message.lowercased()
 return lower.contains("auth")
 || lower.contains("unauthorized")
 || lower.contains("forbidden")
 || lower.contains("token")
 || lower.contains("scope")
 || lower.contains("credential")
 }

 private func isProtocolVersionMessage(_ message: String) -> Bool {
 let lower = message.lowercased()
 return lower.contains("protocol") && lower.contains("version")
 }

 private func isTLSMessage(_ message: String) -> Bool {
 let lower = message.lowercased()
 return lower.contains("tls")
 || lower.contains("ssl")
 || lower.contains("certificate")
 || lower.contains("secure connection")
 }
}
