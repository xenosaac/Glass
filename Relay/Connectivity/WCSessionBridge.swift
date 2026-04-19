import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity

/// iPhone-side bridge for sending data to / receiving data from a Watch companion.
///
/// stub — the Watch companion (Module K) is a stretch goal.
/// This file exists so the iPhone target compiles cleanly with `WCSession`
/// imported, and so a future K session can drop in implementation
/// without touching anything else.
public final class WCSessionBridge: NSObject, @unchecked Sendable {
 public static let shared = WCSessionBridge()

 private override init() { super.init() }

 /// Activate the WCSession. K wires the delegate + reachability.
 public func activate() {
 // K:
 // guard WCSession.isSupported else { return }
 // let session = WCSession.default
 // session.delegate = self
 // session.activate
 }

 /// Send a payload to the Watch (best effort, requires reachable session).
 public func send(_ payload: [String: Any]) {
 // K:
 // WCSession.default.sendMessage(payload, replyHandler: nil) { error in ... }
 }
}
#endif
