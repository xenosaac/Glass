import XCTest
@testable import Relay

/// — unit tests for the cloud image-encoding fix.
///
/// Before , `GeminiClient.encodeMessages` contained a literal
/// `case .image: continue` that silently dropped every uploaded image on
/// the cloud path. That was the #1 root cause of "Gemini can't see my
/// images" reported by the user.
///
/// These tests pin the new behavior: `.image(URL)` blocks become
/// `{"inlineData": {"mimeType": "...", "data": "<base64>"}}` parts per
/// Gemini REST vision spec (camelCase), with a surfaced-text fallback
/// when the file is missing instead of a silent drop.
final class GeminiClientImageEncodingTests: XCTestCase {

 private func makeClient() -> GeminiClient {
 // A dummy key is fine — we never call `stream(...)` which is what
 // uses the key. `encodeMessages` is pure on the instance.
 return GeminiClient(apiKey: "test-unused")
 }

 private func makeTempJPEG() throws -> URL {
 let url = FileManager.default.temporaryDirectory
 .appendingPathComponent("relay-gemini-test-\(UUID().uuidString).jpg")
 // JPEG magic bytes (SOI marker + JFIF) — enough for
 // `FileManager.fileExists(atPath:)` and for base64 encoding. Cactus
 // / Gemini do real decoding at runtime, not here.
 let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]
 try Data(bytes).write(to: url)
 return url
 }

 private func makeTempPNG() throws -> URL {
 let url = FileManager.default.temporaryDirectory
 .appendingPathComponent("relay-gemini-test-\(UUID().uuidString).png")
 // PNG signature bytes.
 let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
 try Data(bytes).write(to: url)
 return url
 }

 // MARK: - Happy path: JPEG

 func test_userTurnWithTextAndImage_emitsInlineDataPart() throws {
 let tmp = try makeTempJPEG
 defer { try? FileManager.default.removeItem(at: tmp) }

 let client = makeClient
 let messages: [RelayMessage] = [
 .user(UserContent(blocks: [
 .text("What is in this image?"),
 .image(tmp)
 ]))
 ]
 let contents = client.encodeMessages(messages)
 XCTAssertEqual(contents.count, 1, "one user turn → one content entry")
 XCTAssertEqual(contents[0]["role"] as? String, "user")

 let parts = contents[0]["parts"] as? [[String: Any]]
 XCTAssertNotNil(parts, "user turn must have parts array")
 // Expect two parts: text + inlineData (order matters for the model).
 XCTAssertEqual(parts?.count, 2, "text + inlineData")
 XCTAssertEqual(parts?[0]["text"] as? String, "What is in this image?")

 let inline = parts?[1]["inlineData"] as? [String: Any]
 XCTAssertNotNil(inline, "second part must be inlineData")
 XCTAssertEqual(inline?["mimeType"] as? String, "image/jpeg")
 let data = inline?["data"] as? String
 XCTAssertNotNil(data)
 XCTAssertFalse(data?.isEmpty ?? true, "base64 data must be non-empty")
 }

 // MARK: - Missing file: surface note, no inlineData

 func test_userTurnWithMissingImage_fallsBackToTextNote() throws {
 let bogus = URL(fileURLWithPath: "/does/not/exist/\(UUID().uuidString).jpg")

 let client = makeClient
 let messages: [RelayMessage] = [
 .user(UserContent(blocks: [
 .text("Explain the photo."),
 .image(bogus)
 ]))
 ]
 let contents = client.encodeMessages(messages)
 XCTAssertEqual(contents.count, 1)

 let parts = contents[0]["parts"] as? [[String: Any]]
 XCTAssertNotNil(parts)

 // No inlineData anywhere.
 for part in parts ?? [] {
 XCTAssertNil(part["inlineData"], "missing-file path must NOT emit inlineData")
 }

 // At least one text part must contain the "could not be loaded" surface note.
 let textParts = (parts ?? []).compactMap { $0["text"] as? String }
 let joined = textParts.joined(separator: " | ")
 XCTAssertTrue(
 joined.contains("could not be loaded"),
 "surface-fail text must mention 'could not be loaded'; got: \(joined)"
 )
 }

 // MARK: - PNG MIME

 func test_userTurnWithPngImage_emitsCorrectMimeType() throws {
 let tmp = try makeTempPNG
 defer { try? FileManager.default.removeItem(at: tmp) }

 let client = makeClient
 let messages: [RelayMessage] = [
 .user(UserContent(blocks: [.image(tmp)]))
 ]
 let contents = client.encodeMessages(messages)
 XCTAssertEqual(contents.count, 1)

 let parts = contents[0]["parts"] as? [[String: Any]]
 let inline = parts?.first?["inlineData"] as? [String: Any]
 XCTAssertNotNil(inline, "png-only turn must still emit inlineData")
 XCTAssertEqual(inline?["mimeType"] as? String, "image/png")
 }
}
