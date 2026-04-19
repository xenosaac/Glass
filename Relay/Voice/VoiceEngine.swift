import Foundation
import Observation
import UIKit

/// Orchestrates the voice input pipeline:
/// capture → streaming transcription → silence detection → WAV save → submission.
///
/// Owns: `AudioCaptureSession`.
/// Uses: `SharedVoiceRuntime` for Whisper (shared across sessions).
/// Does NOT own: Gemma-4 host or `AgentCore` (those stay in `ChatViewModel`).
@Observable
public final class VoiceEngine: @unchecked Sendable {

 // MARK: - Dependencies

 private let voiceRuntime: SharedVoiceRuntime

 public init(voiceRuntime: SharedVoiceRuntime) {
 self.voiceRuntime = voiceRuntime
 }

 // MARK: - Public state

 public enum Phase: Sendable, Equatable {
 case idle
 case loadingWhisper
 case listening
 case processing
 case error(String)
 }

 public private(set) var phase: Phase = .idle
 public private(set) var partialTranscript: String = ""
 public private(set) var finalTranscript: String = ""
 public private(set) var audioLevel: Float = 0
 public private(set) var recordingDuration: TimeInterval = 0
 /// Set to true when finalize completes and audio was submitted.
 public private(set) var didComplete: Bool = false

 // MARK: - Configuration

 /// tuned 2.0s → 0.8s. OpenAI Realtime API recommends
 /// 500-800 ms of silence to mark turn-end; combined with Cactus's
 /// <0.3s Whisper-Small transcription this gives total turn-end latency
 /// ~1.1s after the user stops speaking. 2.0s felt sluggish for a true
 /// voice agent loop.
 private let silenceTimeoutSeconds: TimeInterval = 0.8
 private let silenceThreshold: Float = 0.015

 /// Whisper options JSON forwarded to Cactus FFI.
 /// The `language: "en"` hint disables Whisper's auto-detect path which
 /// on short / noisy clips deterministically outputs a max-decode of
 /// the "no speech" token (visible as ". . . . . . . . " in transcripts).
 /// `task: "transcribe"` is explicit (vs "translate") to be defensive.
 fileprivate static let whisperOptionsJson: String =
 #"{"language":"en","task":"transcribe"}"#

 /// ASR backend selection. Default is Apple Speech
 /// (`SFSpeechRecognizer`, on-device since iOS 13) because Cactus's
 /// bundled Whisper-Small was producing the no-speech-token hallucination
 /// on real LOUD speech (device log dated ). Cactus path is
 /// preserved with the language hint above and can be re-enabled by
 /// flipping this flag (or via a future Settings toggle) when the
 /// upstream Cactus issue is fixed.
 public static let useAppleSpeech: Bool = true
 private let maxRecordingSeconds: TimeInterval = 120
 private let minRecordingSeconds: TimeInterval = 1.0
 /// Chunk duration matching AudioCaptureSession
 private let chunkDurationMs: Int = 500

 // MARK: - Private state

 /// Current whisper host reference (obtained from shared runtime).
 private var whisperHost: CactusModelHost?
 private var captureSession: AudioCaptureSession?
 private var streamHandle: CactusStreamTranscribeT?
 private var recordingTask: Task<Void, Never>?
 private var allPCMData = Data
 private var silentChunkCount: Int = 0
 private var recordingStartTime: Date?

 private var onComplete: (@Sendable (String, URL) -> Void)?
 private var onCancel: (@Sendable () -> Void)?
 /// Fired when recording ended with no usable transcript (all-whitespace or
 /// empty Whisper output). Distinct from `onCancel` so the caller can show
 /// a specific "couldn't transcribe" error instead of silently dismissing.
 /// If nil, the engine falls back to `onCancel` — but callers SHOULD wire
 /// this for correct UX.
 private var onFailedTranscription: (@Sendable (String) -> Void)?

 private let queue = DispatchQueue(label: "relay.voiceengine")

 // MARK: - Lifecycle

 /// Start listening. Loads Whisper on first use, starts capture + streaming transcription.
 /// `onFailedTranscription` fires when recording ended with no usable
 /// text (empty Whisper output) — caller should show an error and NOT
 /// submit a turn.
 @MainActor
 public func startListening(
 onComplete: @escaping @Sendable (String, URL) -> Void,
 onCancel: @escaping @Sendable  () -> Void,
 onFailedTranscription: (@Sendable (String) -> Void)? = nil
 ) {
 self.onComplete = onComplete
 self.onCancel = onCancel
 self.onFailedTranscription = onFailedTranscription
 didComplete = false
 partialTranscript = ""
 finalTranscript = ""
 allPCMData = Data
 silentChunkCount = 0
 recordingDuration = 0

 recordingTask = Task { [weak self] in
 await self?.runListeningPipeline
 }
 }

 /// Dictation mode: starts listening and delivers the transcript only.
 /// The WAV that `finalize` writes to disk is deleted immediately after
 /// the transcript is produced so `voiceRecordings/` does not accumulate
 /// orphan files. The caller is expected to drop the transcript into a
 /// composer field for user review — no auto-submit, no audio attached to
 /// the model.
 ///
 /// Post- voice UX: mic button fills the composer instead of
 /// submitting a voice envelope, because sending audio to Gemma produced
 /// channel/thought leakage and re-transcription drift.
 @MainActor
 public func startDictation(
 onTranscript: @escaping @Sendable (String) -> Void,
 onCancel: @escaping @Sendable  () -> Void,
 onFailedTranscription: (@Sendable (String) -> Void)? = nil
 ) {
 startListening(
 onComplete: { transcript, audioURL in
 try? FileManager.default.removeItem(at: audioURL)
 onTranscript(transcript)
 },
 onCancel: onCancel,
 onFailedTranscription: onFailedTranscription
 )
 }

 /// Cancel the current recording. Discards audio.
 @MainActor
 public func cancel() {
 recordingTask?.cancel
 recordingTask = nil

 Task {
 if let handle = streamHandle, let host = whisperHost {
 _ = try? await host.streamTranscribeStop(stream: handle)
 }
 streamHandle = nil
 }
 // tear down Apple Speech if it was the active backend.
 appleSpeech?.cancel
 appleSpeech = nil
 appleSpeechFinalText = ""

 _ = captureSession?.stop
 captureSession = nil

 phase = .idle
 let cb = onCancel
 onCancel = nil
 onComplete = nil
 onFailedTranscription = nil
 cb?
 }

 /// Manually stop and submit (user taps send while still speaking).
 @MainActor
 public func finishAndSubmit() {
 UIImpactFeedbackGenerator(style: .light).impactOccurred
 recordingTask?.cancel
 recordingTask = nil
 Task { [weak self] in
 await self?.finalize
 }
 }

 /// Clear local whisper reference. Does NOT unload the shared model —
 /// that's managed by SharedVoiceRuntime (e.g., on memory warning).
 public func clearWhisperRef() {
 whisperHost = nil
 }

 // MARK: - Pipeline

 /// when `useAppleSpeech` is true the engine holds an
 /// `AppleSpeechTranscriber` instead of using the Cactus stream handle.
 /// Same downstream contract: partials populate `partialTranscript`,
 /// final transcript is delivered via `onComplete` after silence-VAD or
 /// manual stop.
 @MainActor private var appleSpeech: AppleSpeechTranscriber?
 @MainActor private var appleSpeechFinalText: String = ""

 private func runListeningPipeline() async {
 // 1. Get Whisper from shared runtime (already prewarmed at app launch).
 // Even when Apple Speech is the active backend, we still want
 // Whisper hot for any future toggle — but skip the wait so the user
 // isn't blocked by Whisper load.
 let useApple = Self.useAppleSpeech
 if !useApple {
 let isAlreadyReady = await MainActor.run { voiceRuntime.isWhisperReady }
 if !isAlreadyReady {
 await MainActor.run { phase = .loadingWhisper }
 print("[VOICE_START] whisper not ready, waiting...")
 }
 guard let host = await voiceRuntime.ensureWhisperReady else {
 await MainActor.run {
 phase = .error("Whisper model failed to load. Check Settings for details.")
 }
 return
 }
 whisperHost = host
 print("[VOICE_START] whisperReady=true backend=cactus_whisper")
 } else {
 // Apple Speech needs runtime authorization. First call prompts.
 let status = await AppleSpeechTranscriber.requestAuthorization
 guard status == .authorized else {
 await MainActor.run {
 phase = .error("Speech recognition permission was denied. Enable it in Settings → Privacy → Speech Recognition.")
 }
 return
 }
 print("[VOICE_START] backend=apple_speech")
 }

 // Cancellation checkpoint: user may have cancelled during Whisper load
 guard !Task.isCancelled else { return }

 // 2. Start audio capture
 let capture = AudioCaptureSession
 // Wire fail-fast error callback for interruption / route loss
 capture.onError = { [weak self] message in
 Task { @MainActor [weak self] in
 guard let self else { return }
 self.recordingTask?.cancel
 self.recordingTask = nil
 self.captureSession = nil
 // Clean up active Whisper stream
 if let handle = self.streamHandle, let host = self.whisperHost {
 _ = try? await host.streamTranscribeStop(stream: handle)
 }
 self.streamHandle = nil
 self.phase = .error(message)
 UINotificationFeedbackGenerator.notificationOccurred(.warning)
 }
 }
 captureSession = capture

 let pcmStream: AsyncStream<Data>
 do {
 pcmStream = try await capture.start
 } catch {
 await MainActor.run {
 phase = .error("Mic error: \(error.localizedDescription)")
 }
 return
 }

 // Cancellation checkpoint: user may have cancelled during mic permission prompt
 guard !Task.isCancelled else {
 _ = capture.stop
 captureSession = nil
 return
 }

 // 3. Start streaming transcription. Two backends:
 // Apple Speech (default; SFSpeechRecognizer; reliable)
 // Cactus Whisper (fallback; with R7-C language-hint optionsJson)
 if useApple {
 let asr = await MainActor.run { AppleSpeechTranscriber }
 do {
 try await MainActor.run {
 try asr.start(
 onPartial: { [weak self] text in
 Task { @MainActor [weak self] in self?.partialTranscript = text }
 },
 onFinal: { [weak self] text in
 Task { @MainActor [weak self] in self?.appleSpeechFinalText = text }
 },
 onFailure: { [weak self] message in
 Task { @MainActor [weak self] in
 print("[VOICE_TRANSCRIBER] apple_speech error: \(message)")
 self?.phase = .error(message)
 }
 }
 )
 }
 await MainActor.run { self.appleSpeech = asr }
 } catch {
 await MainActor.run {
 phase = .error("Speech start failed: \(error.localizedDescription)")
 }
 _ = capture.stop
 captureSession = nil
 return
 }
 } else {
 // pass language hint so Cactus Whisper skips
 // its auto-detect path. Without this, short clips deterministically
 // output a max-decode of the "no speech" token (rendered as
 // repeated "." chars). Device log: 199 chars of dots from a
 // 3.10s rms=0.1362 utterance — pure auto-detect failure mode.
 do {
 streamHandle = try await whisperHost!.streamTranscribeStart(
 optionsJson: Self.whisperOptionsJson
 )
 } catch {
 await MainActor.run {
 phase = .error("Whisper start failed: \(error.localizedDescription)")
 }
 _ = capture.stop
 captureSession = nil
 return
 }
 }

 await MainActor.run {
 phase = .listening
 recordingStartTime = Date()
 UIImpactFeedbackGenerator(style: .medium).impactOccurred
 }

 // 4. Process loop
 for await chunk in pcmStream {
 guard !Task.isCancelled else { break }
 await processChunk(chunk)
 }
 }

 private func processChunk(_ chunk: Data) async {
 allPCMData.append(chunk)

 // Update duration
 let duration: TimeInterval
 if let start = recordingStartTime {
 duration = Date().timeIntervalSince(start)
 } else {
 duration = 0
 }

 // Update audio level
 let level = captureSession?.currentLevel ?? 0

 await MainActor.run {
 recordingDuration = duration
 audioLevel = level
 }

 // feed audio to whichever ASR backend is active.
 // Both backends update `partialTranscript` as their respective
 // recognizers emit interim results. AppleSpeech populates it via
 // its onPartial callback (wired in start); Cactus pushes it here
 // from each streamTranscribeProcess return.
 let asr = await MainActor.run { self.appleSpeech }
 if asr != nil {
 await MainActor.run { asr?.process(pcmChunk: chunk) }
 } else if let handle = streamHandle, let host = whisperHost {
 do {
 let partial = try await host.streamTranscribeProcess(
 stream: handle, pcm: chunk
 )
 if !partial.isEmpty {
 await MainActor.run { partialTranscript = partial }
 }
 } catch {
 // Non-fatal: keep recording
 }
 }

 // Silence detection
 if level < silenceThreshold {
 silentChunkCount += 1
 } else {
 silentChunkCount = 0
 }

 // Auto-stop: silence detected AND minimum recording reached (audio-level only, no transcript gate)
 let chunksForSilence = Int(silenceTimeoutSeconds * 1000) / chunkDurationMs
 if silentChunkCount >= chunksForSilence && duration >= minRecordingSeconds {
 await MainActor.run { UIImpactFeedbackGenerator(style: .soft).impactOccurred }
 await finalize
 return
 }

 // Safety: max recording
 if duration >= maxRecordingSeconds {
 await finalize
 }
 }

 private func finalize() async {
 await MainActor.run { phase = .processing }

 // Stop capture, get remaining PCM
 if let remaining = captureSession?.stop {
 allPCMData.append(remaining)
 }
 captureSession = nil

 // diagnostic: the device log shows Whisper producing
 // strings of `.` dots with `transcript_len=199`. Log the captured
 // audio's byte count, recording duration, and RMS amplitude so we
 // can disambiguate "mic captured silence" from "Whisper decoded
 // real audio as dots" on the next device rerun.
 let durationSeconds = await MainActor.run { recordingDuration }
 #if DEBUG
 let rms = Self.computeRMS(pcm: allPCMData)
 print("[VOICE_AUDIO] bytes=\(allPCMData.count) duration_s=\(String(format: "%.2f", durationSeconds)) rms=\(String(format: "%.4f", rms))")
 #endif

 // Finalize ASR backend in use.
 let partial = await MainActor.run { partialTranscript }
 var transcript = partial
 let asr = await MainActor.run { self.appleSpeech }
 if let asr {
 // Apple Speech: signal end-of-audio, give the recognizer a brief
 // window to deliver its final result via the onFinal callback.
 await MainActor.run { asr.stop }
 // Drain — wait up to 1.5s for onFinal to land. SFSpeechRecognizer
 // typically delivers within 200-500ms after endAudio on-device.
 for _ in 0..<15 {
 let landed = await MainActor.run { !self.appleSpeechFinalText.isEmpty }
 if landed { break }
 try? await Task.sleep(nanoseconds: 100_000_000)
 }
 let final = await MainActor.run { self.appleSpeechFinalText }
 if !final.isEmpty { transcript = final }
 await MainActor.run {
 self.appleSpeech = nil
 self.appleSpeechFinalText = ""
 }
 } else if let handle = streamHandle, let host = whisperHost {
 do {
 let final = try await host.streamTranscribeStop(stream: handle)
 if !final.isEmpty { transcript = final }
 } catch {
 // Use partial as fallback
 }
 streamHandle = nil
 }

 let finalizedTranscript = transcript
 await MainActor.run { finalTranscript = finalizedTranscript }

 // Gate: recording must produce a non-empty transcript after trim.
 // Audio-exists-alone is NOT sufficient — an empty transcript means
 // Whisper had nothing usable, and submitting `audioRef` without text
 // produces garbage assistant output (channel/thought markup leaking
 // from the chat template with no text context to anchor it).
 var trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
 let streamingEmpty = trimmed.isEmpty

 // Streaming transcription occasionally returns an empty final result
 // even when PCM capture succeeded (e.g. stream-stop race, low-SNR
 // chunks). Before rejecting the turn, run one offline pass over the
 // full captured buffer as a reliability fallback.
 // only fall back to offline Cactus transcribe
 // when the Cactus path was the ACTIVE backend. On Apple Speech,
 // streamingEmpty just means SFSpeechRecognizer didn't report any
 // partials yet (rare; usually onFinal already landed). Skipping
 // this branch avoids accidentally re-introducing the dot
 // hallucination on top of a clean Apple Speech result.
 if streamingEmpty, !allPCMData.isEmpty, let host = whisperHost, !Self.useAppleSpeech {
 do {
 // Same language hint applied to the offline fallback path
 // so both Cactus paths use the identical Whisper config.
 let fallback = try await host.transcribe(
 pcm: allPCMData,
 optionsJson: Self.whisperOptionsJson
 )
 let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
 if !fallbackTrimmed.isEmpty {
 transcript = fallback
 trimmed = fallbackTrimmed
 await MainActor.run { finalTranscript = fallback }
 #if DEBUG
 print("VOICE_FINALIZE fallback=offline_transcribe transcript_len=\(fallbackTrimmed.count)")
 #endif
 }
 } catch {
 #if DEBUG
 print("VOICE_FINALIZE fallback_error=\(error.localizedDescription)")
 #endif
 }
 }

 #if DEBUG
 let whisperPath = streamingEmpty ? "fallback" : "stream"
 let prefix = String(trimmed.prefix(40))
 print("[VOICE_WHISPER] path=\(whisperPath) transcript_len=\(trimmed.count) prefix=\"\(prefix)\"")
 #endif

 // Whisper-small hallucination filter.
 // Whisper occasionally returns punctuation-only ". . . . . . " strings
 // for non-speech audio (background noise, breath, low-SNR speech).
 // Device log: 163 chars of dots from rms=0.0516 audio. Pre-fix
 // these passed `trimmed.isEmpty` and got submitted as a USER
 // message, polluting the conversation. Re-uses the existing
 // `onFailedTranscription` UX path by setting `trimmed = ""`.
 if !trimmed.isEmpty, Self.isLikelyWhisperHallucination(trimmed) {
 #if DEBUG
 let hPrefix = String(trimmed.prefix(40))
 print("[VOICE_WHISPER] rejected=hallucination transcript_len=\(trimmed.count) prefix=\"\(hPrefix)\"")
 #endif
 trimmed = ""
 }

 if trimmed.isEmpty {
 // save the captured PCM as a WAV for later
 // forensic inspection when the recording HAD content (rms > 0,
 // duration meaningful) but Whisper produced nothing usable.
 // Orphan WAVs are capped via pruneRejectedWAVs (last 10 only).
 // Skips when the buffer is genuinely empty (no audio at all).
 if !allPCMData.isEmpty {
 _ = saveWAV(pcmData: allPCMData, prefix: "voice_rejected")
 Self.pruneRejectedWAVs
 }
 #if DEBUG
 print("VOICE_FINALIZE rejected=empty_transcript pcm_bytes=\(allPCMData.count)")
 #endif
 await MainActor.run {
 didComplete = false
 phase = .idle
 }
 let fail = onFailedTranscription
 let cancel = onCancel
 onComplete = nil
 onCancel = nil
 onFailedTranscription = nil
 if let fail {
 fail("I couldn't transcribe that voice message. Please try again, or speak a bit closer to the microphone.")
 } else {
 cancel?
 }
 return
 }

 // Non-empty transcript: save WAV and deliver the turn.
 let audioURL = saveWAV(pcmData: allPCMData)

 await MainActor.run {
 didComplete = true
 phase = .idle
 }

 if let url = audioURL {
 #if DEBUG
 print("VOICE_FINALIZE accepted transcript_len=\(trimmed.count) wav=\(url.lastPathComponent)")
 #endif
 onComplete?(trimmed, url)
 } else {
 // WAV write failed after a valid transcript — surface as cancel,
 // since we can't submit a voice turn without the audio file.
 onCancel?
 }
 onComplete = nil
 onCancel = nil
 onFailedTranscription = nil
 }

 // MARK: - Diagnostics

 /// Root-mean-square amplitude of a 16-bit little-endian mono PCM buffer.
 /// Returned in [0, 1] where 0.0 is digital silence and ~0.3+ is normal
 /// speech near the phone. Used to disambiguate "mic captured silence"
 /// from "Whisper mis-decoded real audio" when the transcript comes out
 /// as dots or empty. O(N) over the sample count.
 private static func computeRMS(pcm: Data) -> Float {
 guard pcm.count >= 2 else { return 0 }
 let sampleCount = pcm.count / 2
 var sumOfSquares: Double = 0
 pcm.withUnsafeBytes { raw in
 let samples = raw.bindMemory(to: Int16.self)
 for i in 0..<sampleCount {
 let s = Double(samples[i]) / 32768.0
 sumOfSquares += s * s
 }
 }
 let mean = sumOfSquares / Double(sampleCount)
 return Float(mean.squareRoot)
 }

 // MARK: - Whisper hallucination detection (R7-A+++ )

 /// Boilerplate strings Whisper-small frequently emits when it has no real
 /// speech to anchor on — bleed-through from its training data (YouTube
 /// captions, podcast outros, audio-book stingers). Match is on the
 /// trimmed, lowercased transcript so casing doesn't matter.
 private static let whisperHallucinationBlacklist: Set<String> = [
 ".", "..", "...", "....", ".....",
 "thank you.", "thank you", "thanks", "thanks for watching.",
 "thanks for watching!", "subscribe to my channel.",
 "bye.", "bye bye.", "you",
 "[music]", "[applause]", "[silence]", "[blank_audio]"
 ]

 /// True when the transcript looks like a Whisper hallucination rather
 /// than real speech. Two checks: (a) exact match against a small known
 /// boilerplate set, (b) low alphanumeric-to-non-whitespace ratio
 /// (catches dot/punctuation walls regardless of length).
 ///
 /// 30% threshold rationale: real sentences run 85-100% alphanumeric
 /// even with heavy punctuation ("Hi! How are you?" = 86%), while
 /// hallucinations like ". . . . . . " are 0%.
 internal static func isLikelyWhisperHallucination(_ text: String) -> Bool {
 let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
 if whisperHallucinationBlacklist.contains(normalized) { return true }

 let nonWhitespace = text.unicodeScalars.filter {
 !CharacterSet.whitespacesAndNewlines.contains($0)
 }
 guard !nonWhitespace.isEmpty else { return true }
 let alphanumericCount = nonWhitespace.filter {
 CharacterSet.alphanumerics.contains($0)
 }.count
 let ratio = Double(alphanumericCount) / Double(nonWhitespace.count)
 return ratio < 0.30
 }

 // MARK: - WAV Writer

 /// `prefix` (R7-C ) tags the filename so accepted vs rejected
 /// recordings are easy to tell apart on disk. Default `"voice"` matches
 /// historic behavior; rejected paths use `"voice_rejected"`.
 private func saveWAV(pcmData: Data, prefix: String = "voice") -> URL? {
 guard !pcmData.isEmpty else { return nil }

 let sampleRate: UInt32 = 16000
 let channels: UInt16 = 1
 let bitsPerSample: UInt16 = 16
 let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
 let blockAlign = channels * (bitsPerSample / 8)
 let dataSize = UInt32(pcmData.count)
 let fileSize = 36 + dataSize

 var header = Data(capacity: 44)
 header.append(contentsOf: "RIFF".utf8)
 header.append(littleEndian: fileSize)
 header.append(contentsOf: "WAVE".utf8)
 header.append(contentsOf: "fmt ".utf8)
 header.append(littleEndian: UInt32(16)) // PCM chunk size
 header.append(littleEndian: UInt16(1)) // PCM format
 header.append(littleEndian: channels)
 header.append(littleEndian: sampleRate)
 header.append(littleEndian: byteRate)
 header.append(littleEndian: blockAlign)
 header.append(littleEndian: bitsPerSample)
 header.append(contentsOf: "data".utf8)
 header.append(littleEndian: dataSize)

 let wavData = header + pcmData
 let filename = "\(prefix)_\(UUID().uuidString.prefix(8)).wav"
 let dir = AppPaths.voiceRecordings
 try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 let url = dir.appendingPathComponent(filename)

 do {
 try wavData.write(to: url)
 return url
 } catch {
 return nil
 }
 }

 /// keep at most the most recent 10 rejected WAVs
 /// on disk for forensics. Older files are deleted so the
 /// voiceRecordings/ directory doesn't grow unbounded across sessions.
 fileprivate static func pruneRejectedWAVs(keepLast: Int = 10) {
 let dir = AppPaths.voiceRecordings
 guard let entries = try? FileManager.default.contentsOfDirectory(
 at: dir,
 includingPropertiesForKeys: [.creationDateKey],
 options: .skipsHiddenFiles
 ) else { return }
 let rejected = entries
 .filter { $0.lastPathComponent.hasPrefix("voice_rejected_") }
 .sorted() { lhs, rhs in
 let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
 let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
 return lhsDate > rhsDate // newest first
 }
 guard rejected.count > keepLast else { return }
 for url in rejected.dropFirst(keepLast) {
 try? FileManager.default.removeItem(at: url)
 }
 }
}

// MARK: - Data + Little-Endian Helpers

private extension Data {
 mutating func append(littleEndian value: UInt32) {
 Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
 }

 mutating func append(littleEndian value: UInt16) {
 Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
 }
}
