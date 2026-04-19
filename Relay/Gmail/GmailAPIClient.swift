import Foundation

// MARK: - Domain types

public struct GmailProfile: Codable, Sendable {
 public let emailAddress: String
}

public struct GmailMessageSummary: Codable, Sendable {
 public let id: String
 public let threadId: String
 public let from: String
 public let subject: String
 public let date: String
 public let snippet: String

 public init(id: String, threadId: String, from: String, subject: String, date: String, snippet: String) {
 self.id = id
 self.threadId = threadId
 self.from = from
 self.subject = subject
 self.date = date
 self.snippet = snippet
 }
}

public struct GmailMessage: Codable, Sendable {
 public let id: String
 public let threadId: String
 public let from: String
 public let to: String
 public let cc: String?
 public let subject: String
 public let date: String
 public let messageIDHeader: String?
 public let referencesHeader: String?
 public let snippet: String
 public let bodyText: String
}

public struct GmailThread: Codable, Sendable {
 public let id: String
 public let messages: [GmailMessage]
}

// MARK: - REST client

/// Gmail REST API client.
/// Injects the access token from `GmailTokenStore` into every request.
/// On 401, tries a single refresh via `GmailAuth.refresh(...)` before failing.
/// Returns parsed domain types, not raw JSON.
public actor GmailAPIClient {
 private let tokenStore: GmailTokenStore
 private let auth: GmailAuth
 private let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
 private let session: URLSession

 public init(tokenStore: GmailTokenStore, auth: GmailAuth) {
 self.tokenStore = tokenStore
 self.auth = auth
 let cfg = URLSessionConfiguration.default
 cfg.timeoutIntervalForRequest = 30
 self.session = URLSession(configuration: cfg)
 }

 // MARK: - Public surface

 public func profile() async throws -> GmailProfile {
 let raw: GmailProfileRaw = try await authorized(
 path: "profile", method: "GET", query: nil, body: nil
 )
 return GmailProfile(emailAddress: raw.emailAddress)
 }

 public func search(query: String, maxResults: Int) async throws -> [GmailMessageSummary] {
 let list: GmailListResponse = try await authorized(
 path: "messages",
 method: "GET",
 query: [("q", query), ("maxResults", String(maxResults))],
 body: nil
 )
 guard let refs = list.messages, !refs.isEmpty else { return [] }
 // Sequential fetch keeps the rate budget simple for small N (≤ 25).
 var out: [GmailMessageSummary] = []
 for ref in refs.prefix(maxResults) {
 if let sum = try? await messageSummary(id: ref.id) {
 out.append(sum)
 }
 }
 return out
 }

 public func messageFull(id: String) async throws -> GmailMessage {
 let raw: GmailRawMessage = try await authorized(
 path: "messages/\(id)",
 method: "GET",
 query: [("format", "full")],
 body: nil
 )
 return raw.parsed
 }

 public func threadFull(id: String) async throws -> GmailThread {
 let raw: GmailRawThread = try await authorized(
 path: "threads/\(id)",
 method: "GET",
 query: [("format", "full")],
 body: nil
 )
 return GmailThread(id: raw.id, messages: raw.messages.map { $0.parsed })
 }

 public func createDraft(raw: String, threadId: String?) async throws -> String {
 var message: [String: Any] = ["raw": raw]
 if let threadId { message["threadId"] = threadId }
 let body: [String: Any] = ["message": message]
 let resp: GmailIDResponse = try await authorized(
 path: "drafts",
 method: "POST",
 query: nil,
 body: try JSONSerialization.data(withJSONObject: body),
 contentType: "application/json"
 )
 return resp.id
 }

 public func sendRaw(raw: String, threadId: String?) async throws -> String {
 var body: [String: Any] = ["raw": raw]
 if let threadId { body["threadId"] = threadId }
 let resp: GmailIDResponse = try await authorized(
 path: "messages/send",
 method: "POST",
 query: nil,
 body: try JSONSerialization.data(withJSONObject: body),
 contentType: "application/json"
 )
 return resp.id
 }

 // MARK: - Helpers

 private func messageSummary(id: String) async throws -> GmailMessageSummary {
 let raw: GmailRawMessage = try await authorized(
 path: "messages/\(id)",
 method: "GET",
 query: [
 ("format", "metadata"),
 ("metadataHeaders", "From"),
 ("metadataHeaders", "Subject"),
 ("metadataHeaders", "Date"),
 ],
 body: nil
 )
 let headers = raw.payload?.headers ?? []
 func h(_ name: String) -> String? {
 headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
 }
 return GmailMessageSummary(
 id: raw.id,
 threadId: raw.threadId ?? raw.id,
 from: h("From") ?? "",
 subject: h("Subject") ?? "(no subject)",
 date: h("Date") ?? "",
 snippet: raw.snippet ?? ""
 )
 }

 // MARK: - Authorized request (with single-shot refresh)

 private func authorized<T: Decodable>(
 path: String,
 method: String,
 query: [(String, String)]?,
 body: Data?,
 contentType: String = "application/json"
 ) async throws -> T {
 var didRetry = false
 while true {
 let token = try await currentAccessToken
 let url = try buildURL(path: path, query: query)
 var req = URLRequest(url: url)
 req.httpMethod = method
 req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
 if let body {
 req.httpBody = body
 req.setValue(contentType, forHTTPHeaderField: "Content-Type")
 }

 let data: Data
 let response: URLResponse
 do {
 (data, response) = try await session.data(for: req)
 } catch {
 throw GmailError.network(error.localizedDescription)
 }
 guard let http = response as? HTTPURLResponse else {
 throw GmailError.network("Non-HTTP response")
 }
 if http.statusCode == 401 && !didRetry {
 didRetry = true
 _ = try await forceRefresh
 continue
 }
 if http.statusCode >= 400 {
 let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
 throw GmailError.httpStatus(http.statusCode, msg)
 }
 do {
 return try JSONDecoder.decode(T.self, from: data)
 } catch {
 throw GmailError.decodeFailed(error.localizedDescription)
 }
 }
 }

 private func buildURL(path: String, query: [(String, String)]?) throws -> URL {
 var comps = URLComponents(
 url: baseURL.appendingPathComponent(path),
 resolvingAgainstBaseURL: false
 )
 if let query {
 comps?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
 }
 guard let url = comps?.url else { throw GmailError.network("Invalid URL") }
 return url
 }

 private func currentAccessToken() async throws -> String {
 guard let tokens = await tokenStore.load else { throw GmailError.notSignedIn }
 if tokens.isExpired {
 return try await forceRefresh
 }
 return tokens.accessToken
 }

 private func forceRefresh() async throws -> String {
 guard let current = await tokenStore.load else { throw GmailError.notSignedIn }
 do {
 let fresh = try await auth.refresh(refreshToken: current.refreshToken)
 let merged = GmailTokens(
 accessToken: fresh.accessToken,
 refreshToken: current.refreshToken,
 expiresAt: fresh.expiresAt,
 userEmail: current.userEmail
 )
 try await tokenStore.save(merged)
 return merged.accessToken
 } catch {
 // Refresh token is dead — clear and surface a signed-out state.
 await tokenStore.clear
 throw GmailError.refreshFailed(error.localizedDescription)
 }
 }
}

// MARK: - Raw decoding types

private struct GmailProfileRaw: Decodable { let emailAddress: String }
private struct GmailIDResponse: Decodable { let id: String }
private struct GmailListResponse: Decodable {
 struct Ref: Decodable { let id: String; let threadId: String }
 let messages: [Ref]?
}
private struct GmailRawThread: Decodable {
 let id: String
 let messages: [GmailRawMessage]
}

struct GmailRawMessage: Decodable {
 let id: String
 let threadId: String?
 let snippet: String?
 let payload: Payload?

 struct Payload: Decodable {
 let mimeType: String?
 let headers: [Header]?
 let body: Body?
 let parts: [Payload]?
 }
 struct Header: Decodable {
 let name: String
 let value: String
 }
 struct Body: Decodable {
 let data: String?
 let size: Int?
 }

 func parsed() -> GmailMessage {
 let headers = payload?.headers ?? []
 func h(_ name: String) -> String? {
 headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
 }
 return GmailMessage(
 id: id,
 threadId: threadId ?? id,
 from: h("From") ?? "",
 to: h("To") ?? "",
 cc: h("Cc"),
 subject: h("Subject") ?? "(no subject)",
 date: h("Date") ?? "",
 messageIDHeader: h("Message-ID") ?? h("Message-Id"),
 referencesHeader: h("References"),
 snippet: snippet ?? "",
 bodyText: Self.extractText(payload) ?? snippet ?? ""
 )
 }

 // Walk the payload tree best-effort for a text/plain body. Falls back to
 // any body data we can decode, then to the snippet.
 private static func extractText(_ payload: Payload?) -> String? {
 guard let payload else { return nil }
 if (payload.mimeType ?? "").hasPrefix("text/plain"),
 let encoded = payload.body?.data,
 let text = decodeBase64URL(encoded) {
 return text
 }
 if let parts = payload.parts {
 // Prefer text/plain at this level
 for part in parts where (part.mimeType ?? "").hasPrefix("text/plain") {
 if let encoded = part.body?.data, let text = decodeBase64URL(encoded) {
 return text
 }
 }
 // Recurse into multipart
 for part in parts {
 if let text = extractText(part) { return text }
 }
 }
 if let encoded = payload.body?.data, let text = decodeBase64URL(encoded) {
 return text
 }
 return nil
 }

 private static func decodeBase64URL(_ s: String) -> String? {
 var padded = s.replacingOccurrences(of: "-", with: "+")
 .replacingOccurrences(of: "_", with: "/")
 while padded.count % 4 != 0 { padded += "=" }
 guard let data = Data(base64Encoded: padded) else { return nil }
 return String(data: data, encoding: .utf8)
 }
}
