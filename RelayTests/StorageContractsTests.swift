import XCTest
@testable import Relay

final class StorageContractsTests: XCTestCase {
 func test_registry_containsAllRequiredStoresExactlyOnce() {
 let expected = Set(PersistedStoreID.allCases)
 let actual = Set(StorageRegistry.all.map(\.id))

 XCTAssertEqual(actual, expected)
 XCTAssertEqual(StorageRegistry.all.count, expected.count)
 }

 func test_registry_exposesAuthorityBackingFormatAndMigrationForEveryStore() {
 for contract in StorageRegistry.all {
 XCTAssertFalse(contract.owner.rawValue.isEmpty)
 XCTAssertFalse(contract.migrationRule.legacyStrategy.rawValue.isEmpty)
 XCTAssertFalse(contract.migrationRule.incompatibleDataStrategy.rawValue.isEmpty)

 switch contract.backing.kind {
 case .applicationSupport:
 XCTAssertNotNil(contract.backing.relativePath)
 XCTAssertNil(contract.backing.suiteName)
 XCTAssertNil(contract.backing.key)
 case .appGroupUserDefaults:
 XCTAssertNotNil(contract.backing.suiteName)
 XCTAssertNotNil(contract.backing.key)
 }

 switch contract.headerLocation.kind {
 case .inlineEnvelope:
 XCTAssertNil(contract.headerLocation.relativePath)
 case .companionFile:
 XCTAssertNotNil(contract.headerLocation.relativePath)
 }

 if contract.authority == .derived {
 XCTAssertNotNil(contract.rebuildSource)
 }
 }
 }

 func test_pendingLaunchAction_contract_matches_publicConstants() {
 let contract = StorageRegistry.contract(for: .pendingLaunchAction)
 XCTAssertEqual(contract.backing.kind, .appGroupUserDefaults)
 XCTAssertEqual(contract.backing.suiteName, LaunchActionStore.appGroupID)
 XCTAssertEqual(contract.backing.key, "glass_pending_launch_action")
 }
}
