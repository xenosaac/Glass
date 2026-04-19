import Foundation

/// Production implementation of `GmailService`. Thin coordinator over
/// `GmailTokenStore`, `GmailAuth`, and `GmailAPIClient` — does not hold
/// mutable state of its own, so it's safely `Sendable`.
public struct GmailServiceImpl: GmailService, Sendable {
 private let tokenStore: GmailTokenStore
 private let auth: GmailAuth
 private let apiClient: GmailAPIClient

 public init() {
 let store = GmailTokenStore
 let auth = GmailAuth
 self.tokenStore = store
 self.auth = auth
 self.apiClient = GmailAPIClient(tokenStore: store, auth: auth)
 }

 // MARK: - Auth state

 public func isConfigured() async -> Bool {
 GmailConfig.isConfigured
 }

 public func isSignedIn() async -> Bool {
 await tokenStore.load != nil
 }

 public func currentUserEmail() async -> String? {
 await tokenStore.load?.userEmail
 }

 public func signIn() async throws {
 guard GmailConfig.isConfigured else { throw GmailError.notConfigured }
 let fresh = try await auth.authenticate
 try await tokenStore.save(fresh)
 // Populate userEmail from /profile if the id_token didn't carry it.
 if fresh.userEmail == nil {
 if let profile = try? await apiClient.profile {
 var updated = fresh
 updated.userEmail = profile.emailAddress
 try? await tokenStore.save(updated)
 }
 }
 }

 public func signOut() async {
 await tokenStore.clear
 }

 // MARK: - Read surface

 public func search(query: String, maxResults: Int) async throws -> [GmailMessageSummary] {
 let capped = max(1, min(maxResults, 25))
 return try await apiClient.search(query: query, maxResults: capped)
 }

 public func messageFull(id: String) async throws -> GmailMessage {
 try await apiClient.messageFull(id: id)
 }

 public func threadFull(id: String) async throws -> GmailThread {
 try await apiClient.threadFull(id: id)
 }

 // MARK: - Compose surface

 public func createDraftReply(sourceMessageID: String, body: String) async throws -> String {
 let source = try await apiClient.messageFull(id: sourceMessageID)
 let raw = Self.buildReplyRFC2822(source: source, body: body)
 return try await apiClient.createDraft(
 raw: raw.base64URLEncoded,
 threadId: source.threadId
 )
 }

 public func sendMessage(
 to: String,
 subject: String,
 body: String,
 inReplyToMessageID: String?
 ) async throws -> String {
 guard !to.isEmpty else { throw GmailError.invalidArgument("'to' is required") }
 var threadId: String? = nil
 var inReplyTo: String? = nil
 var references: String? = nil

 if let srcID = inReplyToMessageID {
 let source = try await apiClient.messageFull(id: srcID)
 threadId = source.threadId
 inReplyTo = source.messageIDHeader
 references = [source.referencesHeader, source.messageIDHeader]
 .compactMap { $0 }
 .joined(separator: " ")
 if references?.isEmpty == true { references = nil }
 }

 let raw = Self.buildRFC2822(
 to: to,
 subject: subject,
 body: body,
 inReplyTo: inReplyTo,
 references: references
 )
 return try await apiClient.sendRaw(raw: raw.base64URLEncoded, threadId: threadId)
 }

 // MARK: - RFC 2822 helpers

 /// Reply prefixes the subject with `Re: ` (if not already present) and
 /// wires `In-Reply-To` + `References` from the source message.
 private static func buildReplyRFC2822(source: GmailMessage, body: String) -> String {
 let replySubject: String
 if source.subject.lowercased().hasPrefix("re:") {
 replySubject = source.subject
 } else {
 replySubject = "Re: \(source.subject)"
 }
 let refs = [source.referencesHeader, source.messageIDHeader]
 .compactMap { $0 }
 .joined(separator: " ")
 return buildRFC2822(
 to: source.from,
 subject: replySubject,
 body: body,
 inReplyTo: source.messageIDHeader,
 references: refs.isEmpty ? nil : refs
 )
 }

 /// Build a simple single-part text/plain RFC 2822 message.
 /// Gmail will fill in `From:` and `Date:` on send.
 private static func buildRFC2822(
 to: String,
 subject: String,
 body: String,
 inReplyTo: String?,
 references: String?
 ) -> String {
 var lines: [String] = []
 lines.append("To: \(to)")
 lines.append("Subject: \(subject)")
 if let inReplyTo { lines.append("In-Reply-To: \(inReplyTo)") }
 if let references { lines.append("References: \(references)") }
 lines.append("MIME-Version: 1.0")
 lines.append("Content-Type: text/plain; charset=UTF-8")
 lines.append("")
 lines.append(body)
 return lines.joined(separator: "\r\n")
 }
}

// MARK: - String → base64url

private extension String {
 func base64URLEncoded() -> String {
 Data(self.utf8).base64URLEncodedString
 }
}
