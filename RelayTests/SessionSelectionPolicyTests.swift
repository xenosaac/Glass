import XCTest
@testable import Relay

final class SessionSelectionPolicyTests: XCTestCase {

 func test_detailSessionID_preservesNilSelection() {
 XCTAssertNil(
 SessionSelectionPolicy.detailSessionID(currentSessionId: nil)
 )
 }

 func test_persistedSessionID_keepsExistingValueWhenUserNavigatesBack() {
 let sessions = [
 SessionMetadata(id: "session-a", title: "A"),
 SessionMetadata(id: "session-b", title: "B")
 ]

 let persisted = SessionSelectionPolicy.persistedSessionID(
 afterSelectionChange: nil,
 currentPersistedSessionId: "session-b",
 sessions: sessions
 )

 XCTAssertEqual(persisted, "session-b")
 }

 func test_persistedSessionID_clearsOnlyWhenNoSessionsRemain() {
 let persisted = SessionSelectionPolicy.persistedSessionID(
 afterSelectionChange: nil,
 currentPersistedSessionId: "session-a",
 sessions: []
 )

 XCTAssertNil(persisted)
 }

 func test_refreshedSelection_keepsExplicitNilSelection() {
 let sessions = [
 SessionMetadata(id: "session-a", title: "A")
 ]

 let selected = SessionSelectionPolicy.refreshedSelection(
 currentSessionId: nil,
 sessions: sessions
 )

 XCTAssertNil(selected)
 }

 func test_refreshedSelection_fallsBackWhenCurrentSessionWasDeleted() {
 let sessions = [
 SessionMetadata(id: "session-a", title: "A"),
 SessionMetadata(id: "session-b", title: "B")
 ]

 let selected = SessionSelectionPolicy.refreshedSelection(
 currentSessionId: "missing-session",
 sessions: sessions
 )

 XCTAssertEqual(selected, "session-a")
 }
}
