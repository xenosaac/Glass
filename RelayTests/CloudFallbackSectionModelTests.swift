import XCTest
@testable import Relay

private final class ThreadSafeBox<T>: @unchecked Sendable {
 var value: T
 init(_ value: T) { self.value = value }
}

@MainActor
final class CloudFallbackSectionModelTests: XCTestCase {

 func test_refresh_masksStoredKeyInline() {
 let model = makeModel(loadResolvedKey: { "abc1234567890" })

 model.refresh

 XCTAssertTrue(model.hasStoredKey)
 XCTAssertTrue(model.showsMaskedStoredKey)
 XCTAssertTrue(model.maskedStoredKey?.hasSuffix("7890") == true)
 XCTAssertEqual(model.maskedStoredKey?.count, 13)
 }

 func test_remove_clearsStoredStateAndReturnsEditableMode() {
 let storedKey = ThreadSafeBox("abc1234567890")
 let model = makeModel(
 loadResolvedKey: { storedKey.value },
 deleteKey: { storedKey.value = "" }
 )
 model.refresh

 model.remove

 XCTAssertFalse(model.hasStoredKey)
 XCTAssertNil(model.maskedStoredKey)
 XCTAssertFalse(model.showsMaskedStoredKey)
 XCTAssertEqual(storedKey.value, "")
 }

 func test_save_persistsAndMasksAfterSuccessfulValidation() async {
 let storedKey = ThreadSafeBox("")
 let savedKeys = ThreadSafeBox([String])
 let model = makeModel(
 loadResolvedKey: { storedKey.value },
 saveKey: { key in
 savedKeys.value.append(key)
 storedKey.value = key
 },
 validateKey: { _ in }
 )
 model.refresh
 model.draftKey = "gemini-key-1234"

 let changed = await model.save
 model.refresh

 XCTAssertTrue(changed)
 XCTAssertEqual(savedKeys.value, ["gemini-key-1234"])
 XCTAssertTrue(model.maskedStoredKey?.hasSuffix("1234") == true)
 XCTAssertEqual(model.maskedStoredKey?.count, "gemini-key-1234".count)
 XCTAssertTrue(model.showsMaskedStoredKey)
 XCTAssertNil(model.errorMessage)
 }

 func test_save_failure_doesNotPersistKeyAndKeepsDraft() async {
 let storedKey = ThreadSafeBox("")
 let savedKeys = ThreadSafeBox([String])
 let model = makeModel(
 loadResolvedKey: { storedKey.value },
 saveKey: { key in
 savedKeys.value.append(key)
 storedKey.value = key
 },
 validateKey: { _ in
 throw GeminiClient.GeminiError.networkError("timeout")
 }
 )
 model.refresh
 model.draftKey = "bad-key-9999"

 let changed = await model.save

 XCTAssertFalse(changed)
 XCTAssertTrue(savedKeys.value.isEmpty)
 XCTAssertEqual(model.draftKey, "bad-key-9999")
 XCTAssertNil(model.maskedStoredKey)
 XCTAssertEqual(model.errorMessage, GeminiClient.GeminiError.networkError("timeout").localizedDescription)
 }

 func test_save_refusesOverwriteUntilCurrentKeyRemoved() async {
 let model = makeModel(loadResolvedKey: { "old-key-1234" })
 model.refresh
 model.draftKey = "new-key-9999"

 let changed = await model.save

 XCTAssertFalse(changed)
 XCTAssertTrue(model.maskedStoredKey?.hasSuffix("1234") == true)
 XCTAssertEqual(model.errorMessage, "Remove the current key before saving a new one.")
 }

 private func makeModel(
 loadResolvedKey: @escaping @Sendable  () -> String,
 saveKey: @escaping @Sendable (String) throws -> Void = { _ in },
 deleteKey: @escaping @Sendable  () -> Void = {},
 reloadConfig: @escaping @Sendable  () -> Void = {},
 validateKey: @escaping @Sendable (String) async throws -> Void = { _ in }
 ) -> CloudFallbackSectionModel {
 CloudFallbackSectionModel(
 dependencies: .init(
 loadResolvedKey: loadResolvedKey,
 saveKey: saveKey,
 deleteKey: deleteKey,
 reloadConfig: reloadConfig,
 validateKey: validateKey
 )
 )
 }
}
