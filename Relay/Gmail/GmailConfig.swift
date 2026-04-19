import Foundation

/// Personal-workflow Gmail OAuth configuration.
///
/// ## Provisioning (one-time, by the app owner)
///
/// 1. In Google Cloud Console → APIs & Services → Credentials, create an
/// OAuth 2.0 Client ID of type **iOS**. Bundle ID: `com.isaac.relay`.
/// 2. Enable the **Gmail API** for the same project.
/// 3. Paste the Client ID (format `NNNN-xxxx.apps.googleusercontent.com`)
/// into `clientID` below.
/// 4. Paste the reversed Client ID (format
/// `com.googleusercontent.apps.NNNN-xxxx`) into the app's
/// `CFBundleURLTypes` entry, maintained in `project.yml` at
/// `targets.Relay.info.properties.CFBundleURLTypes[0].CFBundleURLSchemes[0]`.
/// Registering the scheme in Info.plist is required: it establishes that
/// this app owns the OAuth redirect URI, prevents scheme-squatting by
/// other apps, and matches what Google's iOS-type OAuth client expects.
/// `ASWebAuthenticationSession` intercepts the redirect inside its own
/// web view, but iOS still validates that the scheme is declared by the
/// bundle; omitting the entry yields a broken flow on real devices.
/// 5. Regenerate the Xcode project (`xcodegen generate`) and rebuild.
///
/// ## Source of truth
///
/// `clientID` — Swift-only constant, below.
/// Reversed Client ID scheme — Info.plist (`CFBundleURLTypes`). The Swift
/// property `callbackURLScheme` below reads it from the Info.plist at
/// runtime so there is no second hardcoded copy. Client ID and scheme
/// are always a pair: if either is missing or still set to the placeholder,
/// `isConfigured` is `false`, the Settings UI shows "Not configured", and
/// Gmail tools stay hidden from the agent.
public enum GmailConfig {
 /// OAuth 2.0 Client ID from Google Cloud Console. Paste here.
 public static let clientID = "630756077109-ja2uhgjb3b0lp09s874luo5foi601gh9.apps.googleusercontent.com"

 /// Reversed Client ID, read from the Info.plist `CFBundleURLTypes` array.
 /// Returns an empty string while the placeholder is still in place,
 /// which keeps `isConfigured` `false`.
 public static var callbackURLScheme: String {
 guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
 else { return "" }
 for entry in types {
 guard let name = entry["CFBundleURLName"] as? String, name == infoPlistURLName,
 let schemes = entry["CFBundleURLSchemes"] as? [String],
 let first = schemes.first,
 !first.isEmpty,
 !first.contains(placeholderMarker)
 else { continue }
 return first
 }
 return ""
 }

 /// Redirect URI passed to Google's authorization endpoint.
 /// iOS standard is `<reversed-client-id>:/oauth2redirect`.
 public static var redirectURI: String {
 callbackURLScheme.isEmpty ? "" : "\(callbackURLScheme):/oauth2redirect"
 }

 /// Requested scopes. `gmail.modify` covers read + compose + send + draft.
 /// `openid` + `userinfo.email` lets us display the signed-in address.
 public static let scopes = [
 "https://www.googleapis.com/auth/gmail.modify",
 "https://www.googleapis.com/auth/userinfo.email",
 "openid",
 ]

 /// Whether the OAuth Client ID and callback scheme are both configured.
 public static var isConfigured: Bool {
 !clientID.isEmpty && !callbackURLScheme.isEmpty
 }

 // MARK: - Info.plist lookup constants

 /// Must match `CFBundleURLName` in `project.yml`'s
 /// `info.properties.CFBundleURLTypes` entry.
 private static let infoPlistURLName = "com.isaac.relay.gmail"

 /// Substring that marks the placeholder scheme. If the scheme in
 /// Info.plist still contains this marker, treat the app as unconfigured.
 private static let placeholderMarker = "REPLACE_WITH_YOUR_CLIENT_ID"
}

/// Unified error surface for the Gmail provider.
public enum GmailError: Error, LocalizedError, Sendable {
 case notConfigured
 case notSignedIn
 case authCancelled
 case authFailed(String)
 case refreshFailed(String)
 case httpStatus(Int, String)
 case decodeFailed(String)
 case invalidArgument(String)
 case network(String)

 public var errorDescription: String? {
 switch self {
 case .notConfigured:
 return "Gmail is not configured. Set GmailConfig.clientID in code and paste the reversed Client ID into project.yml's CFBundleURLTypes, then regenerate."
 case .notSignedIn:
 return "Not signed in to Gmail. Connect your account in Settings → Gmail."
 case .authCancelled:
 return "Gmail sign-in was cancelled."
 case .authFailed(let m):
 return "Gmail sign-in failed: \(m)"
 case .refreshFailed(let m):
 return "Gmail session expired (\(m)). Please reconnect in Settings → Gmail."
 case .httpStatus(let code, let m):
 return "Gmail API error (\(code)): \(m)"
 case .decodeFailed(let m):
 return "Gmail response parse error: \(m)"
 case .invalidArgument(let m):
 return "Invalid argument: \(m)"
 case .network(let m):
 return "Network error: \(m)"
 }
 }
}
