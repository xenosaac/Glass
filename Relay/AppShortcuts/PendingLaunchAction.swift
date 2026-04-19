import Foundation

/// Launch action queued by an App Shortcut (or other external trigger) for the
/// app shell to consume on next foreground pass.
///
/// App Intents can execute in a separate extension-host process with its own
/// sandbox — `UserDefaults.standard` writes there are not visible to the main
/// app. This payload must therefore be persisted in an App Group-backed
/// `UserDefaults` suite that both sides share.
public enum PendingLaunchAction: Codable, Equatable, Sendable {
 case none
 case startVoice
 case askText(String)
}

/// Thin persistence wrapper over the shared App Group defaults.
///
/// `set` is idempotent (last writer wins). `consume` atomically reads and
/// clears. If the shared suite cannot be created (missing entitlement, bad
/// suite name), all operations become no-ops and `consume` returns `.none` —
/// the app continues to function without shortcut handoff rather than crashing.
public enum LaunchActionStore {
 private static let contract = StorageRegistry.contract(for: .pendingLaunchAction)
 private static let key = contract.backing.key ?? "glass_pending_launch_action"

 /// Single source of truth for the App Group identifier. Must match the
 /// value in `Relay.entitlements` and in Apple Developer portal for the
 /// bundle ID `com.isaac.relay`.
 public static let appGroupID = contract.backing.suiteName ?? "group.com.isaac.relay"

 internal static var defaultsProvider:  () -> UserDefaults? = {
 UserDefaults(suiteName: appGroupID)
 }

 /// Shared defaults for the App Group. `nil` if the suite cannot be
 /// initialized (entitlement missing, bad identifier, etc.).
 private static var shared: UserDefaults? {
 defaultsProvider()
 }

 public static func set(_ action: PendingLaunchAction) {
 guard let defaults = shared,
 let data = try? JSONEncoder().encode(
 VersionedStoreEnvelope(header: contract.schemaHeader, payload: action)
 ) else { return }
 defaults.set(data, forKey: key)
 }

 public static func consume() -> PendingLaunchAction {
 guard let defaults = shared,
 let data = defaults.data(forKey: key) else {
 return .none
 }

 if let envelope = try? JSONDecoder().decode(VersionedStoreEnvelope<PendingLaunchAction>.self, from: data),
 envelope.header.isCompatible(with: contract) {
 defaults.removeObject(forKey: key)
 return envelope.payload
 }

 if let action = try? JSONDecoder().decode(PendingLaunchAction.self, from: data) {
 defaults.removeObject(forKey: key)
 return action
 }

 if let envelope = try? JSONDecoder().decode(VersionedStoreEnvelope<PendingLaunchAction>.self, from: data),
 !envelope.header.isCompatible(with: contract) {
 return .none
 }

 return .none
 }
}
