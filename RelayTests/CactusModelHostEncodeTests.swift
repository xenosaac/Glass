import XCTest
@testable import Relay

/// + E.3 — unit tests for the pure helpers in `CactusModelHost`:
/// - `stripChannelSpans(_:)` removes Gemma-4 thinking-mode `<|channel>…<channel|>`
/// leakage from the `response` field.
/// - `encodeMessages(_:systemPrompt:assistantPrefill:)` translates Relay
/// multimodal blocks into Cactus's native `images:[path]` / `audios:[path]`
/// top-level keys (see `cactus/docs/cactus_engine.md:123-128`). The prior
/// `image_url` / `input_audio` content-block shape was a silent no-op.
final class CactusModelHostEncodeTests: XCTestCase {

 // MARK: - stripChannelSpans

 func test_stripChannelSpans_returnsInputWhenNoChannelTag() {
 let input = "Your name is Isaac. I can help with that."
 XCTAssertEqual(CactusModelHost.stripChannelSpans(input), input)
 }

 func test_stripChannelSpans_removesSingleSpan() {
 let input = "<|channel>thought\nLet me think about this.<channel|>The answer is Paris."
 XCTAssertEqual(CactusModelHost.stripChannelSpans(input), "The answer is Paris.")
 }

 func test_stripChannelSpans_removesMultipleSpans() {
 let input = "<|channel>step 1<channel|>First, open the file. <|channel>step 2<channel|>Then read line 42."
 XCTAssertEqual(
 CactusModelHost.stripChannelSpans(input),
 "First, open the file. Then read line 42."
 )
 }

 func test_stripChannelSpans_handlesUnclosedTagByTruncating() {
 // If the response is cut off mid-thinking, drop everything from
 // the unclosed `<|channel>` onward rather than leak raw tokens.
 let input = "Got it. <|channel>thought, but stream ended here"
 XCTAssertEqual(CactusModelHost.stripChannelSpans(input), "Got it.")
 }

 func test_stripChannelSpans_trimsSurroundingWhitespace() {
 let input = " <|channel>x<channel|> The answer. "
 XCTAssertEqual(CactusModelHost.stripChannelSpans(input), "The answer.")
 }

 // MARK: - encodeMessages text-only turn

 func test_encodeMessages_textOnlyUserTurnUsesStringContent() throws {
 let messages: [RelayMessage] = [
 .user(UserContent(blocks: [.text("Hello there")]))
 ]
 let json = try CactusModelHost.encodeMessages(messages)
 let arr = try decodeJSONArray(json)
 XCTAssertEqual(arr.count, 1)
 XCTAssertEqual(arr[0]["role"] as? String, "user")
 XCTAssertEqual(arr[0]["content"] as? String, "Hello there")
 XCTAssertNil(arr[0]["images"])
 XCTAssertNil(arr[0]["audios"])
 }

 // MARK: - encodeMessages multimodal

 func test_encodeMessages_imageTurnUsesTopLevelImagesKey() throws {
 let tmp = try makeTempImageFile
 defer { try? FileManager.default.removeItem(at: tmp) }

 let messages: [RelayMessage] = [
 .user(UserContent(blocks: [
 .text("What is in this image?"),
 .image(tmp)
 ]))
 ]
 let json = try CactusModelHost.encodeMessages(messages)
 let arr = try decodeJSONArray(json)
 XCTAssertEqual(arr.count, 1)
 let msg = arr[0]
 XCTAssertEqual(msg["role"] as? String, "user")
 // Content must be a plain string (NOT an array of blocks).
 XCTAssertEqual(msg["content"] as? String, "What is in this image?")
 // Images must appear as top-level `images` array of absolute paths.
 let images = msg["images"] as? [String]
 XCTAssertEqual(images?.count, 1)
 XCTAssertEqual(images?.first, tmp.path(percentEncoded: false))
 XCTAssertNil(msg["audios"])
 }

 func test_encodeMessages_missingImageSurfacesPlaceholderTextAndOmitsKey() throws {
 let bogus = URL(fileURLWithPath: "/does/not/exist/image.jpg")
 let messages: [RelayMessage] = [
 .user(UserContent(blocks: [
 .text("Explain the photo."),
 .image(bogus)
 ]))
 ]
 let json = try CactusModelHost.encodeMessages(messages)
 let arr = try decodeJSONArray(json)
 XCTAssertEqual(arr.count, 1)
 let msg = arr[0]
 // Missing file => do NOT emit `images` key at all.
 XCTAssertNil(msg["images"])
 // A placeholder text fragment must be concatenated into `content`
 // so the model at least knows an image was attempted.
 let content = msg["content"] as? String ?? ""
 XCTAssertTrue(content.contains("Explain the photo."))
 XCTAssertTrue(content.contains("[image at /does/not/exist/image.jpg could not be loaded"))
 }

 // MARK: - helpers

 private func decodeJSONArray(_ json: String) throws -> [[String: Any]] {
 guard let data = json.data(using: .utf8),
 let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
 throw NSError(domain: "decode", code: 0, userInfo: nil)
 }
 return arr
 }

 private func makeTempImageFile() throws -> URL {
 let url = FileManager.default.temporaryDirectory
 .appendingPathComponent("relay-test-\(UUID().uuidString).jpg")
 // 1×1 JPEG magic bytes are enough — we only need the file to exist
 // for `FileManager.fileExists(atPath:)` to succeed. Cactus will do
 // its own decoding at runtime.
 let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]
 try Data(bytes).write(to: url)
 return url
 }
}
