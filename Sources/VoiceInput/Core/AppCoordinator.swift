import AppKit

/// Orchestrates a single push-to-talk dictation cycle driven by the Fn key.
///
/// Lifecycle, all on the MAIN thread:
///   Fn down  → snapshot the target app + the dictation language, then start a short
///              hold timer. Nothing visible happens yet.
///   ≥ 400ms  → begin recording: show the capsule and start the transcriber.
///   Fn up    → if the hold never reached the threshold, do nothing: no recording
///              starts, so a quick Fn tap never flashes the capsule or spins up the
///              microphone. (The tap still suppresses the Fn event, but the
///              system's input-source switch happens below the event tap and is
///              unaffected — quick taps stay usable for switching input.)
///              Otherwise stop the transcriber, optionally refine the text via the
///              LLM ("Refining…"), then dismiss the capsule and inject the text.
///
/// The 400ms debounce is what makes a quick Fn tap a no-op for recording.
///
/// Privacy: this type never logs, prints, or persists transcribed text, audio,
/// keystrokes, or the API key. The transcript lives only in memory for the
/// duration of one cycle and is handed straight to the injector.
final class AppCoordinator {

    /// Single-cycle state machine. Overlapping cycles are rejected because there
    /// is exactly one capsule window.
    private enum State {
        case idle
        case pending    // Fn is down but the hold threshold hasn't elapsed yet.
        case recording
        case refining
    }

    /// Minimum Fn hold before a recording actually begins. Below this, the press is
    /// treated as a plain tap and ignored (no capsule, no microphone).
    private static let minimumHold: TimeInterval = 0.4

    private let transcriber = SpeechTranscriber()
    private let capsule = FloatingCapsuleWindow()
    private let refiner = LLMRefiner()

    /// Frontmost-app snapshot taken at Fn-down, used to verify focus before
    /// injecting at Fn-up. Cleared once consumed.
    private var injectionContext: InjectionContext?

    /// Dictation locale resolved at the instant Fn is pressed (so Auto mode reads
    /// the input source before any hold-induced switch can change it).
    private var pendingLanguage: String = "zh-CN"

    /// Fires once the hold threshold elapses; cancelled on an early Fn-up.
    private var holdTimer: Timer?

    private var state: State = .idle

    init() {}

    /// Fn pressed: snapshot context + language and arm the hold timer. MAIN thread.
    func handleFnDown() {
        guard state == .idle else { return }
        state = .pending

        // Snapshot the target field and the dictation language NOW, before our
        // (non-activating) capsule or a hold-induced input-source switch can change
        // anything.
        injectionContext = TextInjector.captureContext()
        pendingLanguage = resolveLanguage()

        // Only begin recording if Fn is still held past the threshold.
        let timer = Timer(timeInterval: AppCoordinator.minimumHold, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .pending else { return }
            self.beginRecording()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// Fn released. MAIN thread.
    func handleFnUp() {
        switch state {
        case .pending:
            // Released before the threshold: a short tap. Cancel and start no
            // recording. (We don't re-emit the Fn event; the system's input-source
            // switch happens below our tap and is unaffected.)
            cancelHoldTimer()
            injectionContext = nil
            state = .idle

        case .recording:
            finishRecording()

        case .idle, .refining:
            // Stray up (e.g. a reconciled edge after a tap); ignore.
            break
        }
    }

    // MARK: - Private

    /// Begin the actual recording once the hold threshold is met.
    private func beginRecording() {
        holdTimer = nil
        state = .recording

        capsule.showListening(language: pendingLanguage)

        // Both transcriber callbacks fire on the main thread per contract.
        transcriber.onPartialText = { [weak self] text in
            self?.capsule.updateText(text)
        }
        transcriber.onLevel = { [weak self] level in
            self?.capsule.updateLevel(level)
        }

        do {
            try transcriber.start(language: pendingLanguage,
                                  onDevice: Settings.shared.onDeviceRecognition)
        } catch {
            // The engine/recognizer could not start. Reset state SYNCHRONOUSLY so a
            // concurrent Fn-up during the 0.22s exit animation is ignored (avoids a
            // double dismiss), then animate the capsule away.
            tearDownCallbacks()
            injectionContext = nil
            state = .idle
            capsule.dismiss(completion: nil)
        }
    }

    /// Stop the transcriber, optionally refine, then inject + dismiss.
    private func finishRecording() {
        cancelHoldTimer()

        let raw = transcriber.stop()
        // Stop forwarding any late audio buffers to the (soon to be hidden) capsule.
        tearDownCallbacks()

        let hasText = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if Settings.shared.llmEnabled, LLMRefiner.isConfigured(), hasText {
            state = .refining
            capsule.showRefining(language: pendingLanguage)

            // refine(_:) reads its configuration from Settings + Keychain itself
            // and is conservative: on any failure it returns `raw` unchanged.
            let refiner = self.refiner
            Task { [weak self] in
                let refined = await refiner.refine(raw)
                await MainActor.run { [weak self] in
                    self?.finish(refined)
                }
            }
        } else {
            finish(raw)
        }
    }

    /// Dismiss the capsule and, once it is gone, inject the text into the field
    /// that was focused when recording began. Resolves the machine back to `.idle`.
    private func finish(_ text: String) {
        let context = injectionContext
        injectionContext = nil

        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard !isEmpty, let context = context else {
            capsule.dismiss { [weak self] in
                self?.state = .idle
            }
            return
        }

        capsule.dismiss { [weak self] in
            self?.state = .idle
            // TextInjector re-verifies the frontmost app against `context` and
            // refuses to type into secure fields; it owns all paste/clipboard
            // handling and never logs the text.
            TextInjector.inject(text, expected: context)
        }
    }

    /// Resolve the dictation locale: in Auto mode, follow the current input source
    /// (falling back to the fixed language if unmappable); otherwise the fixed pick.
    private func resolveLanguage() -> String {
        if Settings.shared.languageFollowsInputSource {
            return InputSourceLanguage.currentRecognitionLanguage(
                fallback: Settings.shared.recognitionLanguage)
        }
        return Settings.shared.recognitionLanguage
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// Detach the live transcription callbacks so a buffer dispatched just before
    /// `stop()` cannot update a capsule that is being dismissed.
    private func tearDownCallbacks() {
        transcriber.onPartialText = nil
        transcriber.onLevel = nil
    }
}
