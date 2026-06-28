import Foundation
import AVFoundation
import Speech
import VoiceInputCore

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
///
/// Long / multi-utterance dictation (the composition logic lives in the pure,
/// unit-tested `TranscriptComposer`; this type just feeds it recognizer callbacks
/// under the lock and caches its `composed` output in `transcript`):
/// - `transcript` is the FULL composed live string and is what `stop()` returns. A
///   short single-utterance hold never commits, so its output is identical to a plain
///   best-transcription stream.
/// - Apple's streaming recognizer silently endpoints after a short pause and REPLACES
///   `bestTranscription` with a fresh short string (no `isFinal`). The composer DETECTS
///   that backward jump and commits the prior segment so it is not lost — and, when the
///   reset is a *rewind* that re-transcribes already-committed audio, suppresses the
///   overlap so the chunk is not duplicated.
/// - Around the ~1-minute on-device cap the task can terminate with an error and
///   stop emitting. We react by swapping in a fresh request + task while keeping
///   the SAME engine + tap, so dictation continues across the seam.
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

    /// Everything below is touched from background queues (the audio tap and the
    /// recognition handler) as well as the main thread (start/stop), so every
    /// access is serialized through `transcriptLock`. The only relaxation is in
    /// `start()`, where these are published while still single-threaded BEFORE the
    /// tap or task can fire.
    private let transcriptLock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Full composed live transcript returned by `stop()`. Cached from `composer`
    /// so `stop()` can return it without recomposing.
    private var transcript: String = ""
    /// Pure transcript state machine (commit-across-resets + overlap suppression).
    /// Touched only under `transcriptLock`.
    private var composer = TranscriptComposer()
    /// Monotonic tag, bumped on every start / restart / stop, so a retired task's
    /// late callbacks are recognized as stale and ignored.
    private var generation: Int = 0
    /// Set first in `stop()` so an in-flight `restart()` no-ops and racing
    /// callbacks bail out.
    private var isStopping: Bool = false
    /// Whether on-device recognition was negotiated for this session; a restart
    /// rebuilds its request with the same setting.
    private var useOnDeviceRecognition: Bool = false

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

        // Honor the on-device preference only when the locale actually supports it;
        // otherwise leave it server-based so recognition still works.
        let useOnDevice = onDevice && recognizer.supportsOnDeviceRecognition
        let request = SpeechTranscriber.makeRequest(onDevice: useOnDevice)

        // Configure the input tap using the input node's native output format.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw TranscriberError.audioInputUnavailable
        }

        // Remove any lingering tap before installing (idempotent / crash-safe).
        inputNode.removeTap(onBus: 0)

        // Reset session state and publish the request/recognizer BEFORE installing
        // the tap, so the very first captured buffer already has a live request to
        // append to (the tap reads `self.request` under the lock).
        transcriptLock.lock()
        transcript = ""
        composer.reset()
        isStopping = false
        generation += 1
        let gen = generation
        useOnDeviceRecognition = useOnDevice
        self.recognizer = recognizer
        self.request = request
        self.task = nil
        transcriptLock.unlock()

        // ONE tap for the entire session. It appends to whichever request is
        // current (start's or a restart's) under a tiny lock, and computes the RMS
        // level OUTSIDE the lock so the realtime audio thread is never blocked on
        // math. The request is swapped by `restart()`, never the engine or the tap.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.transcriptLock.lock()
            self.request?.append(buffer)
            self.transcriptLock.unlock()
            let level = SpeechTranscriber.normalizedRMSLevel(from: buffer)
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(level)
            }
        }

        // Start the engine; on failure, fully unwind so we never leave a half-open
        // session behind. The task is attached only AFTER a successful start (below),
        // so a failed start can never spawn a callback — or a restart.
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            transcriptLock.lock()
            isStopping = true
            generation += 1
            self.request = nil
            self.recognizer = nil
            transcriptLock.unlock()
            request.endAudio()
            throw TranscriberError.engineStartFailed
        }

        // Engine is live: attach the recognition task. The result handler may fire
        // on a background queue; all state mutation is lock-guarded and the UI
        // callback hops to main.
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleResult(result, error: error, generation: gen)
        }
        transcriptLock.lock()
        self.task = task
        transcriptLock.unlock()

        isRunning = true
    }

    /// Handles one recognition callback. Runs on a background queue. Stale-task and
    /// post-stop callbacks are filtered by `generation` / `isStopping`.
    private func handleResult(_ result: SFSpeechRecognitionResult?,
                              error: Error?,
                              generation taskGeneration: Int) {
        transcriptLock.lock()

        // Ignore callbacks from a retired task or after stop() has begun.
        guard taskGeneration == generation, !isStopping else {
            transcriptLock.unlock()
            return
        }

        if let result = result {
            // The composer detects Apple's silent endpoint reset, commits across it,
            // and suppresses re-transcription overlap (the rewind that would otherwise
            // duplicate a chunk). `isFinal` only arrives mid-session when the recognizer
            // hits its cap; committing here lets us restart without losing capture.
            let didFinalize = result.isFinal
            composer.apply(result.bestTranscription.formattedString, isFinal: didFinalize)

            let composed = composer.composed
            transcript = composed
            transcriptLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onPartialText?(composed)
            }

            // restart() re-checks `isStopping`/`generation` under the lock, so a
            // stop() racing here is handled. A benign final delivered by stop()'s or
            // restart()'s own endAudio carries a retired generation and never reaches
            // this branch (filtered by the guard at the top of handleResult).
            if didFinalize {
                restart()
            }
            return
        }

        if error != nil {
            // Mid-session failure (e.g. the ~1-minute on-device cap). Commit what we
            // have, then swap in a fresh request + task to keep dictation alive. A
            // benign cancellation from `stop()` is already filtered above because
            // `stop()` sets `isStopping` and bumps `generation` first.
            composer.commitOnError()
            transcript = composer.composed
            transcriptLock.unlock()
            restart()
            return
        }

        transcriptLock.unlock()
    }

    /// Swaps in a fresh recognition request + task without disturbing the audio
    /// engine or its tap. No-ops if the session is stopping. Bumping `generation`
    /// both serializes restarts and invalidates the retired task's late callbacks.
    private func restart() {
        transcriptLock.lock()
        guard !isStopping, let recognizer = self.recognizer else {
            transcriptLock.unlock()
            return
        }
        generation += 1
        let gen = generation
        let oldRequest = self.request
        let oldTask = self.task
        let newRequest = SpeechTranscriber.makeRequest(onDevice: useOnDeviceRecognition)
        // Publish the new request under the lock BEFORE ending the old one, so the
        // tap never appends to an already-ended request.
        self.request = newRequest
        transcriptLock.unlock()

        // Attach the replacement task (tagged with the new generation)...
        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handleResult(result, error: error, generation: gen)
        }

        // ...then retire the old request/task now that the replacement is live.
        oldRequest?.endAudio()
        oldTask?.cancel()

        transcriptLock.lock()
        if isStopping || gen != generation {
            // A racing stop()/restart() superseded us; drop this task cleanly.
            transcriptLock.unlock()
            newTask.cancel()
            return
        }
        self.task = newTask
        transcriptLock.unlock()
    }

    /// Stops audio capture and recognition, returning the full composed transcript
    /// captured so far. Safe to call when not running (returns the last transcript).
    @discardableResult
    func stop() -> String {
        guard isRunning else {
            return currentTranscript()
        }
        isRunning = false

        // Set the stop gate FIRST and invalidate the current generation so any
        // in-flight `restart()` no-ops and late callbacks are ignored.
        transcriptLock.lock()
        isStopping = true
        generation += 1
        let request = self.request
        let task = self.task
        transcriptLock.unlock()

        // Stop the engine FIRST so the audio render thread halts and no further
        // buffers are delivered to the tap; only then is it safe to end the request.
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Cancel to suppress late callbacks; we already hold the best partial.
        task?.cancel()

        transcriptLock.lock()
        self.task = nil
        self.request = nil
        self.recognizer = nil
        transcriptLock.unlock()

        return currentTranscript()
    }

    // MARK: Transcript composition (thread-safe)

    /// Builds a fresh streaming request with this app's fixed configuration. Shared
    /// by `start()` and `restart()` so a restarted request matches the original.
    private static func makeRequest(onDevice: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if onDevice {
            request.requiresOnDeviceRecognition = true
        }
        return request
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
