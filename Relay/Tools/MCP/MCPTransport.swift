import Foundation

struct HTTPTransportMetadata {
 let statusCode: Int
 let headers: [String: String]
 let contentType: String?

 func headerValue(named name: String) -> String? {
 headers[name.lowercased()]
 }
}

struct HTTPTransportResponse<T: Codable> {
 let result: T
 let metadata: HTTPTransportMetadata
}

/// HTTP transport for MCP JSON-RPC 2.0 over HTTP.
///
/// Sends POST requests with JSON body, parses JSON-RPC responses.
/// Follows the WebSearchTool pattern for URLSession usage.
public actor HTTPTransport {
 private let baseURL: URL
 private let session: URLSession
 private var customHeaders: [String: String]
 private var timeout: TimeInterval
 private var sessionID: String?
 private var protocolVersion: String?

 public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 30, headers: [String: String] = [:]) {
 self.baseURL = baseURL
 self.session = session
 self.timeout = timeout
 self.customHeaders = headers
 }

 func setSessionID(_ sessionID: String?) {
 self.sessionID = sessionID
 }

 func setProtocolVersion(_ protocolVersion: String?) {
 self.protocolVersion = protocolVersion
 }

 func clearSessionState() {
 sessionID = nil
 protocolVersion = nil
 }

 /// Send a JSON-RPC request and parse the response.
 ///
 /// Parameters:
 /// request: The JSON-RPC request to send
 /// responseType: The expected result type
 /// Returns: The parsed result
 /// Throws: MCPError on failure
 public func send<T: Codable>(
 request: JSONRPCRequest,
 responseType: T.Type
 ) async throws -> T {
 try await sendWithMetadata(request: request, responseType: responseType).result
 }

 func sendWithMetadata<T: Codable>(
 request: JSONRPCRequest,
 responseType: T.Type
 ) async throws -> HTTPTransportResponse<T> {
 Self.log(baseURL: baseURL, "encode \(request.summary)")
 let requestData = try encode(request: request)
 let (data, metadata) = try await executeRequest(request: request, data: requestData)

 guard !data.isEmpty else {
 Self.log(baseURL: baseURL, "empty response body for \(request.summary)")
 throw MCPError.invalidResponse("Response body was empty")
 }

 let decoder = JSONDecoder()
 let rpcResponse: JSONRPCResponse<T>
 do {
 rpcResponse = try decoder.decode(JSONRPCResponse<T>.self, from: data)
 } catch {
 let body = String(data: data, encoding: .utf8) ?? "(binary)"
 Self.log(baseURL: baseURL, "decode failure for \(request.summary) body=\(Self.preview(body))")
 throw MCPError.invalidResponse("Failed to parse response: \(error.localizedDescription). Body: \(body.prefix(500))")
 }

 if let rpcError = rpcResponse.error {
 Self.log(baseURL: baseURL, "jsonrpc error for \(request.summary) code=\(rpcError.code) message=\(rpcError.message)")
 throw MCPError.jsonRPCError(code: rpcError.code, message: rpcError.message)
 }

 guard let result = rpcResponse.result else {
 Self.log(baseURL: baseURL, "missing result and error for \(request.summary)")
 throw MCPError.invalidResponse("Response has no result and no error")
 }

 let sessionStatus = metadata.headerValue(named: "Mcp-Session-Id") == nil ? "absent" : "present"
 Self.log(baseURL: baseURL, "decoded \(request.summary) resultType=\(String(describing: T.self)) sessionHeader=\(sessionStatus)")
 return HTTPTransportResponse(result: result, metadata: metadata)
 }

 /// Send a JSON-RPC request without expecting a typed result (for notifications).
 public func sendNotification(request: JSONRPCRequest) async throws {
 Self.log(baseURL: baseURL, "encode notification \(request.summary)")
 let requestData = try encode(request: request)
 let (data, _) = try await executeRequest(request: request, data: requestData)

 guard !data.isEmpty else {
 Self.log(baseURL: baseURL, "notification \(request.summary) completed with empty body")
 return
 }

 let decoder = JSONDecoder()
 if let rpcResponse = try? decoder.decode(JSONRPCResponse<EmptyResult>.self, from: data),
 let rpcError = rpcResponse.error {
 Self.log(baseURL: baseURL, "notification \(request.summary) returned jsonrpc error code=\(rpcError.code) message=\(rpcError.message)")
 throw MCPError.jsonRPCError(code: rpcError.code, message: rpcError.message)
 }

 let body = String(data: data, encoding: .utf8) ?? "(binary)"
 Self.log(baseURL: baseURL, "notification \(request.summary) completed with body=\(Self.preview(body))")
 }

 private func encode(request: JSONRPCRequest) throws -> Data {
 // Encode request
 let encoder = JSONEncoder()
 do {
 return try encoder.encode(request)
 } catch {
 throw MCPError.invalidResponse("Failed to encode request: \(error.localizedDescription)")
 }
 }

 private func executeRequest(request: JSONRPCRequest, data requestData: Data) async throws -> (Data, HTTPTransportMetadata) {
 // Build URLRequest
 var urlRequest = URLRequest(url: baseURL)
 urlRequest.httpMethod = "POST"
 urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
 // MCP Streamable-HTTP transport spec (+)
 // requires clients to declare Accept for BOTH content types so the
 // server can respond with either a one-shot JSON body or an SSE
 // stream. The hosted Canvas MCP endpoint enforces this strictly and
 // rejected our prior single-Accept request with HTTP 406. SSE
 // response *parsing* is intentionally NOT in this pass — a server
 // that actually returns text/event-stream still surfaces as a
 // downstream JSON-decode failure with the body content-type visible
 // in the error, which becomes the trigger for the SSE pass.
 urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
 urlRequest.timeoutInterval = timeout
 urlRequest.httpBody = requestData

 for (key, value) in customHeaders {
 urlRequest.setValue(value, forHTTPHeaderField: key)
 }

 if let sessionID {
 urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
 }
 if let protocolVersion {
 urlRequest.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
 }

 let loggedHeaders = Self.redactedHeaders(from: urlRequest.allHTTPHeaderFields ?? [:])
 Self.log(
 baseURL: baseURL,
 "-> \(request.summary) headers=\(loggedHeaders) bodyBytes=\(requestData.count)"
 )

 // Execute request
 let data: Data
 let response: URLResponse
 do {
 (data, response) = try await session.data(for: urlRequest)
 } catch let urlError as URLError {
 Self.log(baseURL: baseURL, "network error for \(request.summary) code=\(urlError.code.rawValue) message=\(urlError.localizedDescription)")
 if urlError.code == .timedOut {
 throw MCPError.timeout(server: baseURL.host ?? baseURL.absoluteString)
 }
 throw MCPError.networkError(urlError.localizedDescription)
 } catch {
 Self.log(baseURL: baseURL, "network error for \(request.summary) message=\(error.localizedDescription)")
 throw MCPError.networkError(error.localizedDescription)
 }

 // Check HTTP status
 if let httpResponse = response as? HTTPURLResponse {
 let metadata = metadata(from: httpResponse)
 let sessionHeader = metadata.headerValue(named: "Mcp-Session-Id") == nil ? "absent" : "present"
 let bodyPreview = Self.preview(String(data: data, encoding: .utf8) ?? "(binary)")
 Self.log(
 baseURL: baseURL,
 "<- \(request.summary) status=\(httpResponse.statusCode) contentType=\(metadata.contentType ?? "-") bodyBytes=\(data.count) sessionHeader=\(sessionHeader) body=\(bodyPreview)"
 )
 guard (200...299).contains(httpResponse.statusCode) else {
 let body = String(data: data, encoding: .utf8) ?? ""
 throw MCPError.httpStatus(code: httpResponse.statusCode,
 body: String(body.prefix(200)),
 contentType: metadata.contentType)
 }

 if let contentType = metadata.contentType {
 if contentType.contains("text/event-stream") {
 let ssePayload = try Self.extractJSONPayloadFromSSE(
 data: data,
 request: request,
 baseURL: baseURL
 )
 Self.log(baseURL: baseURL, "decoded one-shot SSE payload for \(request.summary)")
 return (ssePayload, metadata)
 }
 if !contentType.contains("application/json") && !contentType.contains("+json") {
 Self.log(baseURL: baseURL, "unexpected content type for \(request.summary): \(contentType)")
 throw MCPError.invalidResponse("Unexpected Content-Type: \(contentType)")
 }
 }
 return (data, metadata)
 }

 Self.log(baseURL: baseURL, "non-http response for \(request.summary)")
 throw MCPError.invalidResponse("Transport did not return an HTTP response")
 }

 private func metadata(from response: HTTPURLResponse) -> HTTPTransportMetadata {
 let headers = response.allHeaderFields.reduce(into: [String: String]) { partial, entry in
 guard let key = entry.key as? String else { return }
 partial[key.lowercased()] = String(describing: entry.value)
 }
 return HTTPTransportMetadata(
 statusCode: response.statusCode,
 headers: headers,
 contentType: headers["content-type"]?.lowercased()
 )
 }

 private static func log(baseURL: URL, _ message: String) {
 print("[MCP][HTTP][\(baseURL.host ?? baseURL.absoluteString)] \(message)")
 }

 private static func redactedHeaders(from headers: [String: String]) -> String {
 let pairs = headers
 .sorted() { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
 .map { key, value in
 "\(key)=\(isSensitiveHeader(key) ? "<redacted>" : preview(value, limit: 80))"
 }
 return "[\(pairs.joined(separator: ", "))]"
 }

 private static func isSensitiveHeader(_ key: String) -> Bool {
 let lower = key.lowercased()
 return lower.contains("authorization")
 || lower.contains("token")
 || lower.contains("secret")
 || lower.contains("api-key")
 || lower.contains("cookie")
 }

 private static func preview(_ value: String, limit: Int = 160) -> String {
 let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
 if normalized.count <= limit {
 return normalized
 }
 return String(normalized.prefix(limit)) + "..."
 }

 private static func extractJSONPayloadFromSSE(
 data: Data,
 request: JSONRPCRequest,
 baseURL: URL
 ) throws -> Data {
 guard let raw = String(data: data, encoding: .utf8) else {
 throw MCPError.invalidResponse("SSE response body was not valid UTF-8")
 }

 let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
 let eventChunks = normalized.components(separatedBy: "\n\n")
 var firstPayload: Data?

 for chunk in eventChunks {
 let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
 var eventName: String?
 var dataLines: [String] = []

 for line in lines {
 if line.hasPrefix(":") { continue }
 if line.hasPrefix("event:") {
 eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
 continue
 }
 if line.hasPrefix("data:") {
 dataLines.append(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces))
 }
 }

 guard !dataLines.isEmpty else { continue }

 let payloadString = dataLines.joined(separator: "\n")
 guard let payloadData = payloadString.data(using: .utf8) else { continue }
 firstPayload = firstPayload ?? payloadData

 if payloadMatchesRequest(payloadData, requestID: request.id) {
 log(baseURL: baseURL, "matched SSE event=\(eventName ?? "-") for \(request.summary) payload=\(preview(payloadString))")
 return payloadData
 }
 }

 if let firstPayload {
 log(baseURL: baseURL, "using first SSE payload for \(request.summary) because no matching id was found")
 return firstPayload
 }

 throw MCPError.unsupportedContentType("text/event-stream")
 }

 private static func payloadMatchesRequest(_ payloadData: Data, requestID: String?) -> Bool {
 guard let requestID else { return true }
 guard let response = try? JSONDecoder.decode(JSONRPCResponse<AnyCodable>.self, from: payloadData) else {
 return false
 }
 return responseIDString(response.id) == requestID
 }

 private static func responseIDString(_ id: AnyCodable?) -> String? {
 guard let id else { return nil }
 switch id {
 case .string(let value):
 return value
 case .int(let value):
 return String(value)
 case .double(let value):
 if value.rounded(.towardZero) == value {
 return String(Int(value))
 }
 return String(value)
 case .bool(let value):
 return String(value)
 case .null, .array, .dictionary:
 return nil
 }
 }
}

/// Empty result type for notifications
private struct EmptyResult: Codable {}

private extension JSONRPCRequest {
 var summary: String {
 let idDescription = id ?? "notification"
 let paramKeys = params?.keys.sorted().joined(separator: ",") ?? "-"
 return "method=\(method) id=\(idDescription) params=\(paramKeys)"
 }
}
