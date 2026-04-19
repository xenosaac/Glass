import XCTest
@testable import Relay

/// regression guard for the init-order race.
///
/// Pre-hotfix: `SharedServices.memoryStore` was set lazily inside
/// `loadIfNeeded` after Gemma loaded (~16s on a cold start). During
/// that window, `ChatViewModel.init()` could capture the still-nil
/// `sharedServices.memoryStore` into a `MemoryWritebackCoordinator`,
/// silently disabling deterministic writeback for the rest of
/// the chat session.
///
/// Post-hotfix: `SharedServices.init()` eagerly constructs the actor
/// so the property is non-nil from the moment any view body or
/// coordinator can read it.
final class SharedServicesInitTests: XCTestCase {

 @MainActor
 func test_init_eagerlyCreatesMemoryStore() {
 let services = SharedServices
 XCTAssertNotNil(
 services.memoryStore,
 "memoryStore must be non-nil immediately after init so " +
 "MemoryWritebackCoordinator (constructed in ChatViewModel.init() " +
 "during the cold-start warm window) never captures a stale nil."
 )
 }
}
