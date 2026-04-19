import AVFoundation
import Foundation

/// Captures microphone audio as 16kHz mono Int16 PCM chunks.
///
/// Not an actor — AVAudioEngine tap callbacks run on an audio render thread.
/// Thread safety is via a DispatchQueue for the buffer, and an AsyncStream for output.
final class AudioCaptureSession: @unchecked Sendable {

 enum CaptureError: Error, LocalizedError {
 case micPermissionDenied
 case engineStartFailed(String)

 var errorDescription: String? {
 switch self {
 case .micPermissionDenied:
 return "Microphone permission denied"
 case .engineStartFailed(let msg):
 return "Audio engine failed: \(msg)"
 }
 }
 }

 /// Current RMS amplitude (0.0...1.0) for UI waveform visualization.
 /// Updated on main thread from the audio render callback.
 private(set) var currentLevel: Float = 0

 /// Called on audio session interruption or route loss. Fail-fast: recording stops.
 var onError: (@Sendable (String) -> Void)?

 private let engine = AVAudioEngine()
 private let targetSampleRate: Double = 16000
 private let chunkDurationMs: Int = 500
 private var pcmBuffer = Data()
 private let bufferQueue = DispatchQueue(label: "relay.audio.buffer")
 private var continuation: AsyncStream<Data>.Continuation?
 private var interruptionObserver: Any?
 private var routeChangeObserver: Any?

 /// Bytes per chunk: 16kHz * 0.5s * 2 bytes (Int16) = 16000 bytes
 private var bytesPerChunk: Int {
 Int(targetSampleRate) * chunkDurationMs / 1000 * 2
 }

 /// Start capturing. Returns an AsyncStream of PCM Data chunks (16kHz mono Int16).
 func start() async throws -> AsyncStream<Data> {
 // Request mic permission
 let granted = await AVAudioApplication.requestRecordPermission()
 guard granted else { throw CaptureError.micPermissionDenied }

 // Configure audio session for recording + playback (AirPods need both)
 let session = AVAudioSession.sharedInstance()
 try session.setCategory(.playAndRecord, mode: .default,
 options: [.defaultToSpeaker, .allowBluetooth])
 try session.setActive(true)

 // Get input format
 let inputNode = engine.inputNode
 let inputFormat = inputNode.outputFormat(forBus: 0)

 // Target format: 16kHz mono Int16
 guard let outputFormat = AVAudioFormat(
 commonFormat: .pcmFormatInt16,
 sampleRate: targetSampleRate,
 channels: 1,
 interleaved: true
 ) else {
 throw CaptureError.engineStartFailed("Cannot create 16kHz Int16 format")
 }

 guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
 throw CaptureError.engineStartFailed("Cannot create audio converter")
 }

 // Create the output stream
 let stream = AsyncStream<Data> { cont in
 self.continuation = cont
 }

 // Install tap — callback fires on audio render thread
 inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat)
 { [weak self] buffer, _ in
 self?.processBuffer(buffer, converter: converter)
 }

 // Start engine
 do {
 try engine.start()
 } catch {
 throw CaptureError.engineStartFailed(error.localizedDescription)
 }

 // Register for audio session interruption (phone call, etc.)
 interruptionObserver = NotificationCenter.default.addObserver(
 forName: AVAudioSession.interruptionNotification,
 object: nil, queue: .main
 ) { [weak self] notification in
 guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
 type == AVAudioSession.InterruptionType.began.rawValue else { return }
 // Fail-fast: stop capture, signal error
 _ = self?.stop()
 self?.onError?("Recording interrupted by phone call.")
 }

 // Register for audio route change (headphones unplugged, BT disconnect)
 routeChangeObserver = NotificationCenter.default.addObserver(
 forName: AVAudioSession.routeChangeNotification,
 object: nil, queue: .main
 ) { [weak self] notification in
 guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
 reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
 // Fail-fast: audio device disconnected
 _ = self?.stop()
 self?.onError?("Audio device disconnected.")
 }

 return stream
 }

 /// Stop capturing. Returns any remaining buffered PCM data.
 func stop() -> Data? {
 // Remove notification observers
 if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
 if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
 interruptionObserver = nil
 routeChangeObserver = nil

 engine.inputNode.removeTap(onBus: 0)
 engine.stop()

 var remaining: Data?
 bufferQueue.sync {
 if !pcmBuffer.isEmpty {
 remaining = pcmBuffer
 pcmBuffer = Data()
 }
 }
 continuation?.finish()
 continuation = nil

 try? AVAudioSession.sharedInstance().setActive(
 false, options: .notifyOthersOnDeactivation
 )
 return remaining
 }

 // MARK: - Private

 private func processBuffer(_ buffer: AVAudioPCMBuffer,
 converter: AVAudioConverter) {
 // Calculate output frame count for resampled audio
 let ratio = targetSampleRate / buffer.format.sampleRate
 let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
 guard frameCount > 0 else { return }

 guard let convertedBuffer = AVAudioPCMBuffer(
 pcmFormat: converter.outputFormat,
 frameCapacity: frameCount
 ) else { return }

 var error: NSError?
 var consumed = false
 converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
 if consumed {
 outStatus.pointee = .noDataNow
 return nil
 }
 consumed = true
 outStatus.pointee = .haveData
 return buffer
 }

 guard error == nil, convertedBuffer.frameLength > 0 else { return }

 // Extract Int16 bytes
 let byteCount = Int(convertedBuffer.frameLength) * 2
 let data = Data(
 bytes: convertedBuffer.int16ChannelData![0],
 count: byteCount
 )

 // Compute RMS level for waveform UI
 let rms = computeRMS(convertedBuffer)
 DispatchQueue.main.async { [weak self] in
 self?.currentLevel = rms
 }

 // Buffer and emit chunks
 bufferQueue.sync {
 pcmBuffer.append(data)
 while pcmBuffer.count >= bytesPerChunk {
 let chunk = pcmBuffer.prefix(bytesPerChunk)
 pcmBuffer = Data(pcmBuffer.dropFirst(bytesPerChunk))
 continuation?.yield(Data(chunk))
 }
 }
 }

 private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
 guard let samples = buffer.int16ChannelData?[0] else { return 0 }
 let count = Int(buffer.frameLength)
 guard count > 0 else { return 0 }

 var sum: Float = 0
 for i in 0..<count {
 let normalized = Float(samples[i]) / Float(Int16.max)
 sum += normalized * normalized
 }
 return min(sqrt(sum / Float(count)) * 3.0, 1.0) // amplify for visual
 }
}
