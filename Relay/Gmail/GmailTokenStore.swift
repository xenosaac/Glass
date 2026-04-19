import Foundation

/// Persisted OAuth tokens for the single Gmail account.
public struct GmailTokens: Codable, Sendable {
 public var accessToken: String
 public var refreshToken: String
 public var expiresAt: Date
 public var userEmail: String?

 /// Returns true if the access token is within 30 seconds of expiry.
 public var isExpired: Bool {
 Date() >= expiresAt.addingTimeInterval(-30)
 }
}

/// Keychain-backed token persistence. Actor-isolated for safety under
/// concurrent access from the auth flow and the API client.
public actor GmailTokenStore {
 private let service = "com.isaac.relay.gmail"
 private let account = "default"

 public init() {}

 public func load() -> GmailTokens? {
 guard let data = try? Keychain.load(service: service, account: account) else { return nil }
 return try? JSONDecoder().decode(GmailTokens.self, from: data)
 }

 public func save(_ tokens: GmailTokens) throws {
 let data = try JSONEncoder().encode(tokens)
 try Keychain.store(data, service: service, account: account)
 }

 public func clear() {
 try? Keychain.delete(service: service, account: account)
 }
}
