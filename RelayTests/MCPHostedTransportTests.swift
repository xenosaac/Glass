import XCTest
@testable import Relay

final class MCPHostedTransportTests: XCTestCase {
 override func setUp() {
 super.setUp
 StubURLProtocol.reset
 }

 override func tearDown() {
 StubURLProtocol.reset
 super.tearDown
 }

 func test_transportSendsDualAcceptHeader() async throws {
 let session = makeSession
 let transport = HTTPTransport(baseURL: URL(string: "https://example.com/mcp")!, session: session)

 StubURLProtocol.handler = { request in
 let response = makeHTTPResponse(
 url: request.url!,
 headers: ["Content-Type": "application/json"]
 )
 let body = try jsonData([
 "jsonrpc": "2.0",
 "id": "response-1",
 "result": ["tools": []]
 ])
 return (response, body)
 }

 _ = try await transport.send(
 request: JSONRPCRequest(method: "tools/list"),
 responseType: MCPToolsListResult.self
 )

 let requests = StubURLProtocol.recordedRequests
 XCTAssertEqual(requests.count, 1)
 XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"),
 "application/json, text/event-stream")
 }

 func test_transportParsesOneShotSSEResponse() async throws {
 let session = makeSession
 let transport = HTTPTransport(baseURL: URL(string: "https://example.com/mcp")!, session: session)
 let request = JSONRPCRequest(method: "tools/list")

 StubURLProtocol.handler = { incoming in
 let response = makeHTTPResponse(
 url: incoming.url!,
 headers: ["Content-Type": "text/event-stream"]
 )
 let payload = try jsonData([
 "jsonrpc": "2.0",
 "id": request.id ?? "",
 "result": ["tools": []]
 ])
 return (response, sseEventBody(payload))
 }

 let result = try await transport.send(
 request: request,
 responseType: MCPToolsListResult.self
 )

 XCTAssertTrue(result.tools.isEmpty)
 }

 func test_listTools_autoInitializesAndAttachesSessionHeaders() async throws {
 let client = MCPClient(config: makeConfig, session: makeSession)

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 let response = makeHTTPResponse(
 url: request.url!,
 headers: [
 "Content-Type": "application/json",
 "Mcp-Session-Id": "canvas-session"
 ]
 )
 return (response, try initializeResponse(serverName: "Canvas"))
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "tools/list":
 let response = makeHTTPResponse(
 url: request.url!,
 headers: ["Content-Type": "application/json"]
 )
 return (response, try jsonData([
 "jsonrpc": "2.0",
 "id": "response-2",
 "result": [
 "tools": [[
 "name": "list_assignments",
 "description": "List assignments",
 "inputSchema": ["type": "object"]
 ]]
 ]
 ]))
 default:
 throw NSError(domain: "UnexpectedRequest", code: 1)
 }
 }

 let tools = try await client.listTools(forceRefresh: true)
 XCTAssertEqual(tools.map(\.name), ["list_assignments"])

 let requests = StubURLProtocol.recordedRequests
 XCTAssertEqual(requests.count, 3)
 XCTAssertEqual(try requestMethod(requests[0]), "initialize")
 XCTAssertNil(requests[0].value(forHTTPHeaderField: "Mcp-Session-Id"))
 XCTAssertEqual(try requestMethod(requests[1]), "notifications/initialized")
 XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Mcp-Session-Id"), "canvas-session")
 XCTAssertEqual(requests[1].value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
 XCTAssertEqual(try requestMethod(requests[2]), "tools/list")
 XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Mcp-Session-Id"), "canvas-session")
 XCTAssertEqual(requests[2].value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
 }

 func test_initializeAcceptsOneShotSSEResponseAndPreservesSessionHeaders() async throws {
 let client = MCPClient(config: makeConfig, session: makeSession)

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 let response = makeHTTPResponse(
 url: request.url!,
 headers: [
 "Content-Type": "text/event-stream",
 "Mcp-Session-Id": "canvas-session"
 ]
 )
 return (response, try sseInitializeResponse(serverName: "Canvas", id: requestID(request)))
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "tools/list":
 let response = makeHTTPResponse(
 url: request.url!,
 headers: ["Content-Type": "application/json"]
 )
 return (response, try jsonData([
 "jsonrpc": "2.0",
 "id": "response-sse-tools",
 "result": [
 "tools": [[
 "name": "list_assignments",
 "inputSchema": ["type": "object"]
 ]]
 ]
 ]))
 default:
 throw NSError(domain: "UnexpectedRequest", code: 11)
 }
 }

 let tools = try await client.listTools(forceRefresh: true)
 XCTAssertEqual(tools.map(\.name), ["list_assignments"])

 let requests = StubURLProtocol.recordedRequests
 XCTAssertEqual(requests.count, 3)
 XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Mcp-Session-Id"), "canvas-session")
 XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Mcp-Session-Id"), "canvas-session")
 XCTAssertEqual(requests[2].value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
 }

 func test_callTool_autoInitializesOnFirstUse() async throws {
 let client = MCPClient(config: makeConfig, session: makeSession)

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 return (
 makeHTTPResponse(url: request.url!,
 headers: ["Content-Type": "application/json", "Mcp-Session-Id": "call-session"]),
 try initializeResponse(serverName: "Canvas")
 )
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "tools/call":
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-3",
 "result": [
 "content": [[
 "type": "text",
 "text": "ok"
 ]]
 ]
 ])
 )
 default:
 throw NSError(domain: "UnexpectedRequest", code: 2)
 }
 }

 let result = try await client.callTool(name: "list_assignments", arguments: ["course": "CS121"])
 XCTAssertEqual(result.content.first?.text, "ok")

 let requests = StubURLProtocol.recordedRequests
 XCTAssertEqual(requests.count, 3)
 XCTAssertEqual(try requestMethod(requests[2]), "tools/call")
 XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Mcp-Session-Id"), "call-session")
 }

 func test_clientTrimsAndNormalizesCanvasHeadersBeforeSendingRequests() async throws {
 let client = MCPClient(
 config: MCPServerConfig(
 name: "Canvas",
 baseURL: URL(string: "https://example.com/mcp")!,
 headers: [
 "X-Canvas-Token": " token\n",
 "X-Canvas-URL": "canvas.example.edu "
 ]
 ),
 session: makeSession
 )

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 return (
 makeHTTPResponse(
 url: request.url!,
 headers: [
 "Content-Type": "application/json",
 "Mcp-Session-Id": "trimmed-session"
 ]
 ),
 try initializeResponse(serverName: "Canvas")
 )
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "tools/list":
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-trimmed-tools",
 "result": ["tools": []]
 ])
 )
 default:
 throw NSError(domain: "UnexpectedRequest", code: 12)
 }
 }

 _ = try await client.listTools(forceRefresh: true)

 let requests = StubURLProtocol.recordedRequests
 XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Canvas-Token"), "token")
 XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Canvas-URL"), "https://canvas.example.edu/api/v1")
 }

 func test_listResources_autoInitializesOnFirstUse() async throws {
 let client = MCPClient(config: makeConfig, session: makeSession)

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 return (
 makeHTTPResponse(url: request.url!,
 headers: ["Content-Type": "application/json", "Mcp-Session-Id": "resource-session"]),
 try initializeResponse(serverName: "Canvas")
 )
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "resources/list":
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-4",
 "result": [
 "resources": [[
 "uri": "canvas://course/1",
 "name": "Course",
 "description": "Course resource"
 ]]
 ]
 ])
 )
 default:
 throw NSError(domain: "UnexpectedRequest", code: 3)
 }
 }

 let resources = try await client.listResources
 XCTAssertEqual(resources.map(\.uri), ["canvas://course/1"])
 }

 func test_readResource_autoInitializesOnFirstUse() async throws {
 let client = MCPClient(config: makeConfig, session: makeSession)

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 return (
 makeHTTPResponse(url: request.url!,
 headers: ["Content-Type": "application/json", "Mcp-Session-Id": "read-session"]),
 try initializeResponse(serverName: "Canvas")
 )
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "resources/read":
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-5",
 "result": [
 "contents": [[
 "type": "text",
 "text": "syllabus"
 ]]
 ]
 ])
 )
 default:
 throw NSError(domain: "UnexpectedRequest", code: 4)
 }
 }

 let content = try await client.readResource(uri: "canvas://course/1")
 XCTAssertEqual(content.text, "syllabus")
 }

 func test_concurrentFirstUseDeduplicatesInitialize() async throws {
 let client = MCPClient(config: makeConfig, session: makeSession)
 let counter = RequestCounter

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 await counter.increment
 try await Task.sleep(nanoseconds: 50_000_000)
 return (
 makeHTTPResponse(url: request.url!,
 headers: ["Content-Type": "application/json", "Mcp-Session-Id": "shared-session"]),
 try initializeResponse(serverName: "Canvas")
 )
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "tools/list":
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-6",
 "result": [
 "tools": [[
 "name": "list_assignments",
 "inputSchema": ["type": "object"]
 ]]
 ]
 ])
 )
 case "resources/list":
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-7",
 "result": ["resources": []]
 ])
 )
 default:
 throw NSError(domain: "UnexpectedRequest", code: 5)
 }
 }

 async let tools = client.listTools(forceRefresh: true)
 async let resources = client.listResources
 _ = try await (tools, resources)

 let initializeCount = await counter.value
 XCTAssertEqual(initializeCount, 1)
 }

 func test_statelessServerCanInitializeWithoutSessionHeader() async throws {
 let client = MCPClient(config: makeConfig, session: makeSession)

 StubURLProtocol.handler = { request in
 switch try requestMethod(request) {
 case "initialize":
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try initializeResponse(serverName: "Stateless")
 )
 case "notifications/initialized":
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case "tools/list":
 XCTAssertNil(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
 XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-8",
 "result": ["tools": []]
 ])
 )
 default:
 throw NSError(domain: "UnexpectedRequest", code: 6)
 }
 }

 let tools = try await client.listTools(forceRefresh: true)
 XCTAssertTrue(tools.isEmpty)
 }

 func test_oneFailingServerDoesNotBlockHealthyServerDiscovery() async throws {
 let storeURL = FileManager.default.temporaryDirectory
 .appendingPathComponent(UUID().uuidString)
 .appendingPathExtension("json")
 let defaults = UserDefaults(suiteName: "mcp-provider-\(UUID().uuidString)")!
 let store = MCPConfigStore(fileURL: storeURL, legacyDefaults: defaults)
 let provider = MCPToolProvider(configStore: store, session: makeSession)

 await store.add(MCPServerConfig(name: "Good", baseURL: URL(string: "https://good.example.com/mcp")!))
 await store.add(MCPServerConfig(name: "Bad", baseURL: URL(string: "https://bad.example.com/mcp")!))

 StubURLProtocol.handler = { request in
 let host = request.url?.host ?? ""
 let method = try requestMethod(request)

 switch (host, method) {
 case ("good.example.com", "initialize"):
 return (
 makeHTTPResponse(url: request.url!,
 headers: ["Content-Type": "application/json", "Mcp-Session-Id": "good-session"]),
 try initializeResponse(serverName: "Good")
 )
 case ("good.example.com", "notifications/initialized"):
 return (makeHTTPResponse(url: request.url!, status: 202), Data)
 case ("good.example.com", "tools/list"):
 return (
 makeHTTPResponse(url: request.url!, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "jsonrpc": "2.0",
 "id": "response-9",
 "result": [
 "tools": [[
 "name": "list_assignments",
 "inputSchema": ["type": "object"]
 ]]
 ]
 ])
 )
 case ("bad.example.com", "initialize"):
 return (
 makeHTTPResponse(url: request.url!, status: 500, headers: ["Content-Type": "application/json"]),
 try jsonData([
 "error": "server blew up"
 ])
 )
 default:
 throw NSError(domain: "UnexpectedRequest", code: 7)
 }
 }

 let context = ToolCallContext(
 messages: [],
 session: AgentSession(id: "test", startedAt: Date),
 approvalBroker: DefaultApprovalBroker,
 progress: { _ in },
 services: DefaultServiceLocator
 )

 let tools = await provider.tools(for: context)
 XCTAssertEqual(tools.count, 1)
 XCTAssertEqual(tools.first?.name, "mcp__good__list_assignments")

 let errors = await provider.lastErrors
 XCTAssertEqual(errors.count, 1)
 XCTAssertNotNil(errors["Bad"])
 }

 private func makeSession() -> URLSession {
 let configuration = URLSessionConfiguration.ephemeral
 configuration.protocolClasses = [StubURLProtocol.self]
 return URLSession(configuration: configuration)
 }

 private func makeConfig() -> MCPServerConfig {
 MCPServerConfig(
 name: "Canvas",
 baseURL: URL(string: "https://example.com/mcp")!,
 headers: [
 "X-Canvas-Token": "token",
 "X-Canvas-URL": "canvas.example.edu"
 ]
 )
 }
}

private actor RequestCounter {
 private var count = 0

 func increment() {
 count += 1
 }

 func value() -> Int {
 count
 }
}

private final class StubURLProtocol: URLProtocol {
 static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
 private static let lock = NSLock
 private static var requests: [URLRequest] = []

 static func reset() {
 lock.lock
 handler = nil
 requests = []
 lock.unlock
 }

 static func recordedRequests() -> [URLRequest] {
 lock.lock
 defer { lock.unlock }
 return requests
 }

 override class func canInit(with request: URLRequest) -> Bool {
 true
 }

 override class func canonicalRequest(for request: URLRequest) -> URLRequest {
 request
 }

 override func startLoading() {
 guard let handler = Self.handler else {
 client?.urlProtocol(self, didFailWithError: NSError(domain: "MissingHandler", code: 1))
 return
 }

 Self.lock.lock
 Self.requests.append(request)
 Self.lock.unlock

 Task {
 do {
 let (response, data) = try await handler(request)
 client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
 if !data.isEmpty {
 client?.urlProtocol(self, didLoad: data)
 }
 client?.urlProtocolDidFinishLoading(self)
 } catch {
 client?.urlProtocol(self, didFailWithError: error)
 }
 }
 }

 override func stopLoading() {}
}

private func requestMethod(_ request: URLRequest) throws -> String {
 let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data)
 guard let dict = object as? [String: Any],
 let method = dict["method"] as? String else {
 throw NSError(domain: "MissingMethod", code: 1)
 }
 return method
}

private func requestID(_ request: URLRequest) throws -> String {
 let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data)
 guard let dict = object as? [String: Any],
 let id = dict["id"] as? String else {
 throw NSError(domain: "MissingID", code: 1)
 }
 return id
}

private func initializeResponse(serverName: String) throws -> Data {
 try jsonData([
 "jsonrpc": "2.0",
 "id": "initialize-response",
 "result": [
 "protocolVersion": "2025-06-18",
 "capabilities": [:],
 "serverInfo": [
 "name": serverName,
 "version": "1.0"
 ]
 ]
 ])
}

private func sseInitializeResponse(serverName: String, id: String) throws -> Data {
 let payload = try jsonData([
 "jsonrpc": "2.0",
 "id": id,
 "result": [
 "protocolVersion": "2025-06-18",
 "capabilities": [:],
 "serverInfo": [
 "name": serverName,
 "version": "1.0"
 ]
 ]
 ])
 return sseEventBody(payload)
}

private func sseEventBody(_ payload: Data) -> Data {
 let json = String(decoding: payload, as: UTF8.self)
 let body = "event: message\n" +
 "data: \(json)\n\n"
 return Data(body.utf8)
}

private func jsonData(_ object: [String: Any]) throws -> Data {
 try JSONSerialization.data(withJSONObject: object, options: [])
}

private func makeHTTPResponse(
 url: URL,
 status: Int = 200,
 headers: [String: String] = [:]
) -> HTTPURLResponse {
 HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}
