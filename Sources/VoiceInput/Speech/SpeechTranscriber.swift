import Foundation
import AVFoundation
import Speech

/// Streams microphone audio through `SFSpeechRecognizer`, exposing live partial
/// transcripts and a normalized audio level for the waveform UI.
///
/// Design notes:
/// - macOS has NO `AVAudioSession`; we drive `AVAudioEngine`'s input node directly
///   and tap it to feed both the recognizer and the RMS level meter.
/// - On-device recognition is requested when asked AND supported by the locale;
///   otherwise we fall back to server-based recognition rather than failing.
/// - No audio, transcript text, or any recognition payload is ever logged or
///   written to disk. Nothing in this type prints.
/// - All callbacks documented as "MAIN thread" are hopped to `DispatchQueue.main`
///   because both the audio tap and the recognition task fire on background queues.
final class SpeechTranscriber {

    // MARK: Public callbacks

    /// Latest partial/best transcript. Invoked on the MAIN thread on every update.
    var onPartialText: ((String) -> Void)?

    /// Normalized RMS audio level in 0.0...1.0. Invoked on the MAIN thread,
    /// roughly once per captured audio buffer.
    var onLevel: ((Float) -> Void)?

    /// Whether the engine + recognition task are currently active.
    /// Read/written only on the main thread (start/stop are main-thread entry points).
    private(set) var isRunning: Bool = false

    // MARK: Private audio/recognition state

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Best transcript captured so far. Updated from the recognition task callback
    /// (a background queue) and read by `stop()` on the main thread, so access is
    /// serialized with a lock.
    private let transcriptLock = NSLock()
    private var transcript: String = ""

    private enum TranscriberError: Error {
        case microphoneAccessDenied
        case recognizerUnavailable
        case audioInputUnavailable
        case engineStartFailed
    }

    init() {}

    /// Deterministically unwind any in-flight session if this object is released
    /// while still running. `stop()` is idempotent (guarded by `isRunning`), and all
    /// engine/task callbacks capture `self` weakly, so this is crash-safe.
    deinit {
        _ = stop()
    }

    // MARK: Authorization

    /// Requests Speech recognition + Microphone authorization. The Speech request
    /// is issued first, then the microphone request; `completion(granted)` is called
    /// on the MAIN thread with `true` only if BOTH were granted.
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechGranted = (speechStatus == .authorized)
            // Microphone access is required to feed the recognizer.
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                let granted = speechGranted && micGranted
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }

    // MARK: Lifecycle

    /// Starts the audio engine and a streaming recognition task.
    ///
    /// - Parameters:
    ///   - language: BCP-47 locale identifier (e.g. "zh-CN").
    ///   - onDevice: when `true`, requests on-device recognition if the locale
    ///     supports it; if it does not, silently falls back to server-based
    ///     recognition (does NOT throw).
    /// - Throws: if microphone access is denied, the recognizer is unavailable for
    ///   the locale, the audio input is unusable, or the engine cannot start.
    func start(language: String, onDevice: Bool) throws {
        // Defensive: tear down any prior session so a second `installTap` cannot
        // crash and stale state cannot leak across sessions.
        if isRunning {
            _ = stop()
        }

        // The microphone permission must already be granted (requested at launch).
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw TranscriberError.microphoneAccessDenied
        }

        // Build a recognizer for the requested locale.
        let locale = Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }

        // Build the streaming request.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Honor the on-device preference only when the locale actually supports it;
        // otherwise leave it server-based so recognition still works.
        if onDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // Reset captured transcript for the new session.
        setTranscript("")

        // Configure the input tap using the input node's native output format.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw TranscriberError.audioInputUnavailable
        }

        // Remove any lingering tap before installing (idempotent / crash-safe).
        inputNode.removeTap(onBus: 0)

        // Capture `request` strongly in the tap so buffers always reach a live
        // request; the engine is stopped before `endAudio()` in `stop()`, so we
        // never append after the request has been ended.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, request] buffer, _ in
            request.append(buffer)
            guard let self = self else { return }
            let level = SpeechTranscriber.normalizedRMSLevel(from: buffer)
            DispatchQueue.main.async {
                self.onLevel?(level)
            }
        }

        // Start the recognition task. The result handler may fire on a background
        // queue; transcript mutation is lock-guarded and UI callbacks hop to main.
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self = self else { return }
            guard let result = result else { return }
            let text = result.bestTranscription.formattedString
            self.setTranscript(text)
            DispatchQueue.main.async {
                self.onPartialText?(text)
            }
        }

        // Start the engine; on failure, fully unwind so we never leave a half-open
        // session behind.
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            task.cancel()
            request.endAudio()
            throw TranscriberError.engineStartFailed
        }

        self.recognizer = recognizer
        self.request = request
        self.task = task
        isRunning = true
    }

    /// Stops audio capture and recognition, returning the best transcript captured
    /// so far. Safe to call when not running (returns the last transcript).
    @discardableResult
    func stop() -> String {
        guard isRunning else {
            return currentTranscript()
        }
        isRunning = false

        // Stop the engine FIRST so the audio render thread halts and no further
        // buffers are delivered to the tap; only then is it safe to end the request.
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Cancel to suppress late callbacks; we already hold the best partial.
        task?.cancel()

        task = nil
        request = nil
        recognizer = nil

        return currentTranscript()
    }

    // MARK: Transcript access (thread-safe)

    private func setTranscript(_ value: String) {
        transcriptLock.lock()
        transcript = value
        transcriptLock.unlock()
    }

    private func currentTranscript() -> String {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        return transcript
    }

    // MARK: Level metering

    /// Computes a perceptual audio level in 0.0...1.0 from a PCM buffer by taking
    /// the RMS across all channels and mapping roughly -50 dB...0 dB onto 0...1.
    private static func normalizedRMSLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        let sampleCount: Int
        if buffer.format.isInterleaved {
            // Interleaved: all channels are packed into channelData[0], strided by
            // channelCount. Indexing channelData[1] here would read out of bounds.
            let samples = channelData[0]
            let total = frameLength * channelCount
            for i in 0..<total {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
            sampleCount = total
        } else {
            // Non-interleaved (the macOS input-node default): one pointer per channel.
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = samples[frame]
                    sumOfSquares += sample * sample
                }
            }
            sampleCount = frameLength * channelCount
        }

        guard sampleCount > 0 else { return 0 }
        let meanSquare = sumOfSquares / Float(sampleCount)
        let rms = sqrt(meanSquare)

        // Guard against log10(0); 1e-7 ≈ -140 dB acts as the practical floor.
        let decibels = 20 * log10(max(rms, 1e-7))
        let minDecibels: Float = -50
        let normalized = (decibels - minDecibels) / (0 - minDecibels)
        return min(max(normalized, 0), 1)
    }
}
