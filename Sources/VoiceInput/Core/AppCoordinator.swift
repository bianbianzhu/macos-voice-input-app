import AppKit

/// Orchestrates a single push-to-talk dictation cycle driven by the Fn key.
///
/// Lifecycle, all on the MAIN thread:
///   Fn down  → snapshot the target app, show the capsule, start the transcriber.
///   Fn up    → stop the transcriber, optionally refine the text via the LLM
///              (showing "Refining…"), then dismiss the capsule and inject the
///              text into the originally-focused field.
///
/// Privacy: this type never logs, prints, or persists transcribed text, audio,
/// keystrokes, or the API key. The transcript lives only in memory for the
/// duration of one cycle and is handed straight to the injector.
final class AppCoordinator {

    /// Single-cycle state machine. Overlapping cycles are rejected because there
    /// is exactly one capsule window; allowing a new recording to begin while the
    /// previous one is still refining/dismissing would let the two cycles fight
    /// over that shared window and over the injection context.
    private enum State {
        case idle
        case recording
        case refining
    }

    private let transcriber = SpeechTranscriber()
    private let capsule = FloatingCapsuleWindow()
    private let refiner = LLMRefiner()

    /// Frontmost-app snapshot taken at Fn-down, used to verify focus before
    /// injecting at Fn-up. Cleared once consumed.
    private var injectionContext: InjectionContext?

    private var state: State = .idle

    init() {}

    /// Fn pressed: capture the injection context, show the capsule, and start the
    /// transcriber. Must be called on the MAIN thread.
    func handleFnDown() {
        // Reject a new cycle while one is already recording or refining.
        guard state == .idle else { return }
        state = .recording

        // Snapshot the target field NOW, before our (non-activating) capsule or
        // anything else can shift focus.
        injectionContext = TextInjector.captureContext()

        capsule.showListening()

        // Both transcriber callbacks are documented to fire on the main thread,
        // so they can touch the capsule directly. weak self avoids any retain of
        // the coordinator by the transcriber it owns.
        transcriber.onPartialText = { [weak self] text in
            self?.capsule.updateText(text)
        }
        transcriber.onLevel = { [weak self] level in
            self?.capsule.updateLevel(level)
        }

        do {
            try transcriber.start(language: Settings.shared.recognitionLanguage,
                                  onDevice: Settings.shared.onDeviceRecognition)
        } catch {
            // The engine/recognizer could not start. Tear down cleanly so the
            // capsule does not hang on "Listening…" forever. (We deliberately do
            // not surface the error text, which could echo recognizer internals.)
            tearDownCallbacks()
            injectionContext = nil
            capsule.dismiss { [weak self] in
                self?.state = .idle
            }
        }
    }

    /// Fn released: stop the transcriber, optionally refine, then inject + dismiss.
    /// Must be called on the MAIN thread.
    func handleFnUp() {
        // Ignore a stray key-up that does not correspond to an active recording
        // (e.g. the down event was suppressed because a cycle was in flight).
        guard state == .recording else { return }

        let raw = transcriber.stop()
        // Stop forwarding any late audio buffers to the (soon to be hidden) capsule.
        tearDownCallbacks()

        let hasText = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if Settings.shared.llmEnabled, LLMRefiner.isConfigured(), hasText {
            state = .refining
            capsule.showRefining()

            // refine(_:) reads its configuration from Settings + Keychain itself
            // and is conservative: on any failure it returns `raw` unchanged.
            let refiner = self.refiner
            Task { [weak self] in
                let refined = await refiner.refine(raw)
                // Hop back to the main thread for all UI / injection work.
                await MainActor.run { [weak self] in
                    self?.finish(refined)
                }
            }
        } else {
            finish(raw)
        }
    }

    // MARK: - Private

    /// Dismiss the capsule and, once it is gone, inject the text into the field
    /// that was focused when recording began. Injecting only after the capsule has
    /// ordered out keeps focus clean. Resolves the state machine back to `.idle`.
    private func finish(_ text: String) {
        let context = injectionContext
        injectionContext = nil

        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Nothing usable to inject: just dismiss and reset.
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

    /// Detach the live transcription callbacks so a buffer dispatched just before
    /// `stop()` cannot update a capsule that is being dismissed.
    private func tearDownCallbacks() {
        transcriber.onPartialText = nil
        transcriber.onLevel = nil
    }
}
