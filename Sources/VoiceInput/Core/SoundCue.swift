import AppKit

/// Optional, non-blocking audio cues for the three moments of a dictation cycle —
/// recording started, recording stopped, and an insertion attempt — so the user
/// gets "eyes-free" feedback without watching the floating capsule.
///
/// Gated behind `Settings.soundCuesEnabled` and OFF by default: when the toggle is
/// off, `play(_:)` is a silent no-op, so the app stays quiet unless the user opts
/// in. Cues use the installed macOS system alert sounds (`/System/Library/Sounds`),
/// so nothing is bundled and playback respects the user's system alert volume.
///
/// Privacy: this type never logs, prints, or persists anything — it only plays a
/// fixed, content-free system sound.
enum SoundCue {

    /// The three points in a dictation cycle that get a distinct, subtle cue.
    enum Event {
        case start    // recording began
        case stop     // recording ended (Fn released)
        case done     // about to attempt insertion (paste may still be refused)

        /// Name of a stock macOS system sound. These ship with every macOS
        /// install, so `NSSound(named:)` resolves them without any bundled asset.
        fileprivate var systemSoundName: NSSound.Name {
            switch self {
            case .start: return NSSound.Name("Tink")   // light tick — "listening"
            case .stop:  return NSSound.Name("Pop")    // soft pop  — "stopped"
            case .done:  return NSSound.Name("Glass")  // gentle chime — "inserting"
            }
        }
    }

    /// Play the cue for `event`, but only if the user enabled sound cues. Call on
    /// the main thread. Playback is asynchronous and never blocks the dictation
    /// cycle; a missing system sound is silently ignored.
    static func play(_ event: Event) {
        guard Settings.shared.soundCuesEnabled else { return }
        // `NSSound(named:)` returns a shared, cached instance. Copy it so triggering
        // a cue while a previous one is still sounding can't cut the earlier one off.
        guard let sound = NSSound(named: event.systemSoundName)?.copy() as? NSSound else { return }
        sound.play()
    }
}
