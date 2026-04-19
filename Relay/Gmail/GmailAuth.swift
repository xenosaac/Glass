import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// OAuth 2.0 Authorization Code + PKCE flow for Gmail, driven via
/// `ASWebAuthenticationSession`. The callback URL scheme is registered at
/// runtime (passed to the session), so no `CFBundleURLTypes` entry is needed.
public final class GmailAuth: NSObject, @unchecked Sendable {
 public override init() { super.init() }

 /// Start interactive sign-in. Presents the Google OAuth page, handles the
 /// redirect, exchanges the code for tokens, and returns a fresh `GmailTokens`.
 public func authenticate() async throws -> GmailTokens {
 guard GmailConfig.isConfigured else { throw GmailError.notConfigured }

 let verifier = Self.randomURLSafeString(byteCount: 64)
 let challenge = Self.codeChallenge(for: verifier)
 let state = Self.randomURLSafeString(byteCount: 16)

 var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
 comps.queryItems = [
 URLQueryItem(name: "client_id", value: GmailConfig.clientID),
 URLQueryItem(name: "redirect_uri", value: GmailConfig.redirectURI),
 URLQueryItem(name: "response_type", value: "code"),
 URLQueryItem(name: "scope", value: GmailConfig.scopes.joined(separator: " ")),
 URLQueryItem(name: "code_challenge", value: challenge),
 URLQueryItem(name: "code_challenge_method", value: "S256"),
 URLQueryItem(name: "state", value: state),
 URLQueryItem(name: "access_type", value: "offline"),
 URLQueryItem(name: "prompt", value: "consent"), // always returns a refresh_token
 ]
 guard let authURL = comps.url else { throw GmailError.authFailed("Could not build auth URL") }

 let callbackURL = try await presentAuthSession(url: authURL)

 // Verify state and extract the authorization code
 let cbComps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
 guard cbComps?.queryItems?.first(where: { $0.name == "state" })?.value == state else {
 throw GmailError.authFailed("OAuth state mismatch")
 }
 guard let code = cbComps?.queryItems?.first(where: { $0.name == "code" })?.value else {
 let err = cbComps?.queryItems?.first(where: { $0.name == "error" })?.value ?? "missing code"
 throw GmailError.authFailed("OAuth error: \(err)")
 }

 return try await exchangeCode(code, verifier: verifier)
 }

 /// Exchange a refresh token for a fresh access token. Does not rotate the
 /// refresh token — Google reuses the original.
 public func refresh(refreshToken: String) async throws -> GmailTokens {
 var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
 req.httpMethod = "POST"
 req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
 req.httpBody = Self.formEncode([
 "client_id": GmailConfig.clientID,
 "refresh_token": refreshToken,
 "grant_type": "refresh_token",
 ]).data(using: .utf8)

 let (data, response) = try await URLSession.shared.data(for: req)
 guard let http = response as? HTTPURLResponse else {
 throw GmailError.refreshFailed("No HTTP response")
 }
 if http.statusCode != 200 {
 let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
 throw GmailError.refreshFailed(msg)
 }
 struct Resp: Decodable {
 let access_token: String
 let expires_in: Int
 }
 guard let r = try? JSONDecoder().decode(Resp.self, from: data) else {
 throw GmailError.refreshFailed("Token response parse failed")
 }
 return GmailTokens(
 accessToken: r.access_token,
 refreshToken: refreshToken,
 expiresAt: Date().addingTimeInterval(TimeInterval(r.expires_in)),
 userEmail: nil // caller merges with existing email
 )
 }

 // MARK: - Private

 @MainActor
 private func presentAuthSession(url: URL) async throws -> URL {
 try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
 let session = ASWebAuthenticationSession(
 url: url,
 callbackURLScheme: GmailConfig.callbackURLScheme
 ) { url, error in
 if let error {
 let ns = error as NSError
 if ns.domain == ASWebAuthenticationSessionError.errorDomain,
 ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
 cont.resume(throwing: GmailError.authCancelled)
 } else {
 cont.resume(throwing: GmailError.authFailed(error.localizedDescription))
 }
 return
 }
 guard let url else {
 cont.resume(throwing: GmailError.authFailed("No callback URL"))
 return
 }
 cont.resume(returning: url)
 }
 session.presentationContextProvider = self
 session.prefersEphemeralWebBrowserSession = false
 if !session.start() {
 cont.resume(throwing: GmailError.authFailed("Could not start auth session"))
 }
 }
 }

 private func exchangeCode(_ code: String, verifier: String) async throws -> GmailTokens {
 var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
 req.httpMethod = "POST"
 req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
 req.httpBody = Self.formEncode([
 "client_id": GmailConfig.clientID,
 "code": code,
 "code_verifier": verifier,
 "grant_type": "authorization_code",
 "redirect_uri": GmailConfig.redirectURI,
 ]).data(using: .utf8)

 let (data, response) = try await URLSession.shared.data(for: req)
 guard let http = response as? HTTPURLResponse else {
 throw GmailError.authFailed("No HTTP response")
 }
 if http.statusCode != 200 {
 let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
 throw GmailError.authFailed(msg)
 }
 struct Resp: Decodable {
 let access_token: String
 let refresh_token: String?
 let expires_in: Int
 let id_token: String?
 }
 guard let r = try? JSONDecoder().decode(Resp.self, from: data) else {
 throw GmailError.authFailed("Token response parse failed")
 }
 guard let refresh = r.refresh_token else {
 throw GmailError.authFailed(
 "No refresh token returned. Revoke this app at myaccount.google.com/permissions and try again."
 )
 }
 return GmailTokens(
 accessToken: r.access_token,
 refreshToken: refresh,
 expiresAt: Date().addingTimeInterval(TimeInterval(r.expires_in)),
 userEmail: Self.decodeEmailFromIDToken(r.id_token)
 )
 }

 // MARK: - PKCE + encoding helpers

 private static func randomURLSafeString(byteCount: Int) -> String {
 var bytes = [UInt8](repeating: 0, count: byteCount)
 _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
 return Data(bytes).base64URLEncodedString()
 }

 private static func codeChallenge(for verifier: String) -> String {
 let hash = SHA256.hash(data: Data(verifier.utf8))
 return Data(hash).base64URLEncodedString()
 }

 private static func formEncode(_ dict: [String: String]) -> String {
 var allowed = CharacterSet.alphanumerics
 allowed.insert(charactersIn: "-._~")
 return dict.map { k, v in
 let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
 let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
 return "\(ek)=\(ev)"
 }.joined(separator: "&")
 }

 private static func decodeEmailFromIDToken(_ idToken: String?) -> String? {
 guard let idToken else { return nil }
 let parts = idToken.split(separator: ".")
 guard parts.count >= 2 else { return nil }
 var payload = String(parts[1])
 .replacingOccurrences(of: "-", with: "+")
 .replacingOccurrences(of: "_", with: "/")
 while payload.count % 4 != 0 { payload += "=" }
 guard let data = Data(base64Encoded: payload),
 let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
 let email = obj["email"] as? String else { return nil }
 return email
 }
}

extension GmailAuth: ASWebAuthenticationPresentationContextProviding {
 public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
 // Called by the system on the main thread.
 UIApplication.shared.connectedScenes
 .compactMap { $0 as? UIWindowScene }
 .flatMap { $0.windows }
 .first { $0.isKeyWindow } ?? ASPresentationAnchor()
 }
}

// MARK: - base64url helper

extension Data {
 func base64URLEncodedString() -> String {
 base64EncodedString()
 .replacingOccurrences(of: "+", with: "-")
 .replacingOccurrences(of: "/", with: "_")
 .replacingOccurrences(of: "=", with: "")
 }
}
