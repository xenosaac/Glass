import AVFoundation
import Foundation
import Speech

/// pluggable ASR backend wrapping Apple's
/// `SFSpeechRecognizer` (on-device since iOS 13). Used as the default
/// transcription path because Cactus's bundled Whisper-Small was
/// observed deterministically returning the "no speech" token (rendered
/// as repeated `.` chars) on real LOUD speech (rms=0.1362, 3.10s
/// utterance) — see device log dated
///
/// Same streaming interface as the Cactus Whisper path:
/// start → process(chunk) per audio chunk → stop returns final.
/// Designed to be a drop-in inside `VoiceEngine.runListeningPipeline`.
@MainActor
final class AppleSpeechTranscriber: @unchecked Sendable {

 enum TranscribeError: Error, LocalizedError {
 case permissionDenied
 case recognizerUnavailable
 case startFailed(String)

 var errorDescription: String? {
 switch self {
 case .permissionDenied:
 return "Speech recognition permission was denied. Enable it in Settings → Privacy → Speech Recognition."
 case .recognizerUnavailable:
 return "Speech recognition is not available on this device or for this locale."
 case .startFailed(let msg):
 return "Speech recognition failed to start: \(msg)"
 }
 }
 }

 /// Latest partial transcript produced by the recognizer.
 private(set) var partialTranscript: String = ""

 private let recognizer: SFSpeechRecognizer?
 private var request: SFSpeechAudioBufferRecognitionRequest?
 private var task: SFSpeechRecognitionTask?
 private let inputFormat: AVAudioFormat?

 init() {
 // Use the user's preferred locale, fall back to en-US.
 let preferred = Locale.preferredLanguages.first.map { Locale(identifier: $0) } ?? Locale(identifier: "en-US")
 self.recognizer = SFSpeechRecognizer(locale: preferred) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
 self.inputFormat = AVAudioFormat(
 commonFormat: .pcmFormatInt16,
 sampleRate: 16000,
 channels: 1,
 interleaved: true
 )
 }

 /// Request user permission. Idempotent; safe to call repeatedly.
 static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
 await withCheckedContinuation { continuation in
 SFSpeechRecognizer.requestAuthorization { status in
 continuation.resume(returning: status)
 }
 }
 }

 /// Start a transcription session.
 /// `onPartial`: fired with each interim transcript (`isFinal == false`).
 /// `onFinal`: fired ONCE with the final transcript when the recognizer
 /// marks the result as final (or the request is ended via `stop`).
 /// `onFailure`: fired ONCE if the recognizer errors out before final.
 func start(
 onPartial: @escaping @Sendable (String) -> Void,
 onFinal: @escaping @Sendable (String) -> Void,
 onFailure: @escaping @Sendable (String) -> Void
 ) throws {
 let status = SFSpeechRecognizer.authorizationStatus
 guard status() == .authorized else {
 throw TranscribeError.permissionDenied
 }
 guard let recognizer, recognizer.isAvailable else {
 throw TranscribeError.recognizerUnavailable
 }

 let req = SFSpeechAudioBufferRecognitionRequest()
 req.shouldReportPartialResults = true
 // Force on-device — preserves Glass's no-cloud-for-voice posture.
 // Available iOS 13+; no network round-trips; consistent latency.
 if #available(iOS 13, *) {
 req.requiresOnDeviceRecognition = true
 }
 req.taskHint = .dictation

 let recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
 if let error {
 onFailure(error.localizedDescription)
 self?.cleanup()
 return
 }
 guard let result else { return }
 let text = result.bestTranscription.formattedString
 Task { @MainActor [weak self] in self?.partialTranscript = text }
 if result.isFinal {
 onFinal(text)
 self?.cleanup()
 } else {
 onPartial(text)
 }
 }

 self.request = req
 self.task = recognitionTask
 }

 /// Feed a chunk of 16 kHz mono Int16 PCM bytes (matches AudioCaptureSession's output).
 func process(pcmChunk: Data) {
 guard let request, let format = inputFormat, !pcmChunk.isEmpty else { return }
 let frameCount = AVAudioFrameCount(pcmChunk.count / 2)
 guard frameCount > 0,
 let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
 buffer.frameLength = frameCount
 pcmChunk.withUnsafeBytes { raw in
 guard let src = raw.bindMemory(to: Int16.self).baseAddress,
 let dst = buffer.int16ChannelData?[0] else { return }
 dst.update(from: src, count: Int(frameCount))
 }
 request.append(buffer)
 }

 /// Signal end-of-audio. The recognition task will fire `onFinal` shortly
 /// after with the complete transcript.
 func stop() {
 request?.endAudio()
 // Don't tear down task immediately — it needs to drain pending audio
 // and fire onFinal first. cleanup is invoked from the task callback.
 }

 /// Hard-cancel without finalizing (user dismissed).
 func cancel() {
 task?.cancel()
 cleanup()
 }

 private func cleanup() {
 request = nil
 task = nil
 }
}
