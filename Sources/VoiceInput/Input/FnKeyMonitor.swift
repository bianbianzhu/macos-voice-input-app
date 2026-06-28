import AppKit
import ApplicationServices

/// Watches the hardware **Fn / Globe** key and reports press / release transitions.
///
/// The monitor installs a `CGEvent` tap that listens for `.flagsChanged` events
/// *only*. On each event it inspects a single bit — `.maskSecondaryFn` — and fires
/// `onFnDown` / `onFnUp` on the main thread when that bit toggles. The Fn event is
/// then **suppressed** (the callback returns `nil`) so macOS never sees the Fn press
/// and cannot pop the emoji / dictation picker while the user is dictating.
///
/// Privacy: this type never reads, stores, or logs any keycode or character. It only
/// ever looks at the Fn modifier bit; all other `.flagsChanged` events pass through
/// untouched so normal modifier keys (Shift, Command, …) keep working everywhere.
final class FnKeyMonitor {

    /// Called on the MAIN thread when the Fn key transitions to pressed.
    var onFnDown: (() -> Void)?

    /// Called on the MAIN thread when the Fn key transitions to released.
    var onFnUp: (() -> Void)?

    /// The active event tap, retained while running.
    private var eventTap: CFMachPort?

    /// Run-loop source feeding the tap on the main run loop.
    private var runLoopSource: CFRunLoopSource?

    /// Last observed state of the Fn modifier; drives edge detection.
    private var fnPressed = false

    /// Installs a `CGEvent` tap listening ONLY for `.flagsChanged` and starts
    /// delivering Fn transitions. Returns `false` if the tap could not be created —
    /// most commonly because the app has not been granted Accessibility permission.
    func start() -> Bool {
        // Idempotent: if we're already tapping, report success.
        if eventTap != nil { return true }

        // Listen for flagsChanged events exclusively. Tap-disabled notifications are
        // still delivered to the callback regardless of this mask.
        let eventMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)

        // C function pointer — cannot capture context, so bridge `self` through the
        // tap's `userInfo` (refcon) and recover it inside the callback.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        fnPressed = false
        return true
    }

    /// Stops the tap and tears down the run-loop source. Safe to call repeatedly.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        fnPressed = false
    }

    /// Core tap handler. Runs on the main run loop (where the source is attached).
    ///
    /// - Re-enables the tap if the system disabled it (timeout / user input).
    /// - Suppresses Fn transitions (returns `nil`) and schedules the user callback.
    /// - Passes every other event through unchanged.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables a tap that runs too slowly or on certain user actions;
        // re-arm it so the monitor keeps working for the life of the app.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // While the tap was disabled we may have missed an Fn transition (most
            // dangerously a release). Reconcile our tracked state against the live
            // hardware modifier state and fire any missed edge so a recording can
            // never get stuck and suppression stays correct on the next press.
            reconcileFnState()
            return Unmanaged.passUnretained(event)
        }

        // Defensive: only flagsChanged is in the mask, but never assume.
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        // Inspect ONLY the Fn modifier bit — no keycodes are ever read.
        let fnNow = event.flags.contains(.maskSecondaryFn)

        // No change in the Fn bit means this is some other modifier (Shift, Command,
        // …) toggling. Leave it completely alone.
        if fnNow == fnPressed {
            return Unmanaged.passUnretained(event)
        }

        fnPressed = fnNow

        // Hop to the main run loop for the user callback so the tap callback returns
        // immediately (keeping the event stream responsive) and the suppression takes
        // effect before any UI / capture work runs.
        if fnNow {
            DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
        }

        // Swallow the Fn event so macOS never sees it and cannot open the emoji /
        // dictation picker while we drive recording.
        return nil
    }

    /// Reconcile `fnPressed` with the live hardware Fn state, firing a missed
    /// down/up edge if they disagree. Used after the tap is re-enabled, where a
    /// transition may have occurred while events were not being delivered.
    private func reconcileFnState() {
        let fnNow = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        if fnNow == fnPressed { return }
        fnPressed = fnNow
        if fnNow {
            DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
        }
    }

    deinit {
        stop()
    }
}
