import AppKit
import Carbon

/// A snapshot of the application that held keyboard focus when recording started.
///
/// Captured at record time (`captureContext`) and re-verified at inject time so we
/// never paste into an app the user has since switched away from.
struct InjectionContext {
    let appPID: pid_t
    let bundleID: String?
}

/// Injects transcribed text into the focused field using the system clipboard plus a
/// synthetic Cmd+V.
///
/// Why clipboard + paste rather than synthesizing characters: it is the only reliable
/// way to enter CJK and mixed-script text across arbitrary apps. To stay privacy-safe:
/// the transcribed text is marked Transient/Concealed so clipboard managers ignore it,
/// and the user's *entire* previous clipboard is restored immediately afterward.
///
/// Nothing in this type is ever logged or written to disk. All work runs on the main
/// thread; the restore steps are scheduled on the main run loop.
enum TextInjector {

    // MARK: - Constants

    /// Conventions understood by well-behaved clipboard managers: items tagged with
    /// these types are excluded from clipboard history, so our pasted text never lingers.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// `TISSelectInputSource` is processed asynchronously by HIToolbox, so after a
    /// CJK→ASCII switch we wait this long before pasting; otherwise the synthetic
    /// Cmd+V could still be interpreted under the original input mode.
    private static let inputSwitchSettleDelay: TimeInterval = 0.06

    /// Delays (measured from when the paste is posted) before tearing down the
    /// temporary state. Input source is restored first, then the clipboard, so the
    /// paste has been consumed by the target app before we overwrite the contents.
    private static let inputSourceRestoreDelay: TimeInterval = 0.08
    private static let pasteboardRestoreDelay: TimeInterval = 0.25

    /// 'v' on the ANSI virtual-keycode map.
    private static let vKeyCode: CGKeyCode = 9

    /// Cancelable handles to the still-pending restores from the most recent
    /// injection. A new injection cancels them first so a stale closure can never
    /// clobber the clipboard / input source of a newer cycle. Touched only on the
    /// main thread (the sole entry point and the scheduled work both run there).
    private static var pendingInputSourceRestore: DispatchWorkItem?
    private static var pendingPasteboardRestore: DispatchWorkItem?

    // MARK: - Public API

    /// Snapshot the frontmost app at recording start. Call on the MAIN thread.
    static func captureContext() -> InjectionContext {
        let app = NSWorkspace.shared.frontmostApplication
        return InjectionContext(appPID: app?.processIdentifier ?? -1,
                                bundleID: app?.bundleIdentifier)
    }

    /// Inject `text` into the focused field via clipboard + Cmd+V. MAIN thread only.
    ///
    /// The steps run in the exact order required by the contract; each guard fails
    /// silently (no logging) so a refused injection simply leaves the user's state
    /// untouched.
    static func inject(_ text: String, expected: InjectionContext) {
        // 1. Never paste empty/whitespace-only content.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // 2. The user may have switched apps between recording and injection. Only
        //    paste if the originally-targeted app is still frontmost.
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == expected.appPID else { return }

        // 3. Refuse to paste into a secure (password) text field.
        guard !isFocusedFieldSecure(appPID: expected.appPID) else { return }

        // Cancel any restores still pending from a previous injection so they can
        // never clobber the clipboard / input source we are about to set up.
        pendingInputSourceRestore?.cancel()
        pendingInputSourceRestore = nil
        pendingPasteboardRestore?.cancel()
        pendingPasteboardRestore = nil

        // 4. Preserve the user's full clipboard so we can restore it verbatim.
        let savedPasteboard = snapshotPasteboard()

        // 5. A CJK input *mode* (Pinyin, Kana, Hangul, …) would intercept/mangle a
        //    synthetic paste; switch to an ASCII-capable layout and remember the
        //    original so we can put it back.
        let previousInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var didSwitchInputSource = false
        if let source = previousInputSource, isCJKInputSource(source),
           let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            if TISSelectInputSource(ascii) == noErr {
                didSwitchInputSource = true
            }
        }

        // 6-8. Stage the text, paste it, and schedule the restores. When we switched
        //      the input source, the switch is asynchronous, so defer the paste a beat
        //      to let it actually take effect first; the restore timers are measured
        //      from the paste, not from here.
        let pasteAndScheduleRestores = {
            // Re-verify the 8.7 guards immediately before Cmd+V. On the CJK path the paste
            // is deferred ~60ms for the input-source switch to settle, and the synthetic
            // Cmd+V lands in whatever app is frontmost at post time — so focus could have
            // moved to another app or a secure (password) field during that window. If it
            // has, abort WITHOUT pasting, restoring the input source we already switched so
            // the user is not left stuck in ASCII. (The clipboard has not been touched yet,
            // so nothing else needs restoring.)
            guard let frontmostNow = NSWorkspace.shared.frontmostApplication,
                  frontmostNow.processIdentifier == expected.appPID,
                  !isFocusedFieldSecure(appPID: expected.appPID) else {
                if didSwitchInputSource {
                    restoreInputSource(previousInputSource)
                }
                return
            }

            // Stage the text, marked transient + concealed so managers skip it.
            writeConcealedText(text)
            // Synthesize Cmd+V into the focused field.
            postCommandV()

            // Restore the input source, then the clipboard, once the paste has landed.
            let inputRestore = DispatchWorkItem {
                if didSwitchInputSource {
                    restoreInputSource(previousInputSource)
                }
            }
            pendingInputSourceRestore = inputRestore
            DispatchQueue.main.asyncAfter(deadline: .now() + inputSourceRestoreDelay,
                                          execute: inputRestore)

            let pasteboardRestore = DispatchWorkItem {
                restorePasteboard(savedPasteboard)
            }
            pendingPasteboardRestore = pasteboardRestore
            DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardRestoreDelay,
                                          execute: pasteboardRestore)
        }

        if didSwitchInputSource {
            DispatchQueue.main.asyncAfter(deadline: .now() + inputSwitchSettleDelay,
                                          execute: pasteAndScheduleRestores)
        } else {
            pasteAndScheduleRestores()
        }
    }

    // MARK: - Secure-field detection

    /// True if the element holding keyboard focus is a secure (password) text field.
    ///
    /// Checks both the target application's focused element and the system-wide focused
    /// element; if *either* reports the secure subrole we treat the field as secure and
    /// abort the injection.
    private static func isFocusedFieldSecure(appPID: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(appPID)
        if focusedSubroleIsSecure(of: appElement) { return true }

        let systemElement = AXUIElementCreateSystemWide()
        if focusedSubroleIsSecure(of: systemElement) { return true }

        return false
    }

    private static func focusedSubroleIsSecure(of element: AXUIElement) -> Bool {
        guard let focused = copyAXElement(element, attribute: kAXFocusedUIElementAttribute as CFString) else {
            return false
        }
        guard let subrole = copyAXString(focused, attribute: kAXSubroleAttribute as CFString) else {
            return false
        }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    /// Reads an attribute whose value is itself an `AXUIElement`.
    private static func copyAXElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let result = value,
              CFGetTypeID(result) == AXUIElementGetTypeID() else {
            return nil
        }
        return (result as! AXUIElement)
    }

    /// Reads an attribute whose value is a string.
    private static func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: - Input source

    /// True for input *modes* (the marked-text CJK engines) or any layout that cannot
    /// produce ASCII directly — both would corrupt a synthetic paste.
    private static func isCJKInputSource(_ source: TISInputSource) -> Bool {
        if let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
            let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue()
            if CFStringCompare(type, kTISTypeKeyboardInputMode, []) == .compareEqualTo {
                return true
            }
        }
        if let asciiPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) {
            let asciiCapable = Unmanaged<CFBoolean>.fromOpaque(asciiPtr).takeUnretainedValue()
            if !CFBooleanGetValue(asciiCapable) {
                return true
            }
        }
        return false
    }

    /// Restore the original input source. If that fails for any reason, force an
    /// ASCII-capable source so the user is never left stuck in a mode we selected.
    private static func restoreInputSource(_ previous: TISInputSource?) {
        if let previous = previous, TISSelectInputSource(previous) == noErr {
            return
        }
        if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            TISSelectInputSource(ascii)
        }
    }

    // MARK: - Pasteboard

    /// A verbatim copy of every item and every *concrete* type currently on the
    /// pasteboard. Lazily-promised representations (e.g. file promises) return nil
    /// from `data(forType:)` and therefore cannot be captured or restored; concrete
    /// data (strings, images, RTF, URLs, …) round-trips faithfully.
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshotPasteboard() -> PasteboardSnapshot {
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        if let items = NSPasteboard.general.pasteboardItems {
            for item in items {
                var typeMap: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        typeMap[type] = data
                    }
                }
                if !typeMap.isEmpty {
                    captured.append(typeMap)
                }
            }
        }
        return PasteboardSnapshot(items: captured)
    }

    private static func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        var restored: [NSPasteboardItem] = []
        for typeMap in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in typeMap {
                item.setData(data, forType: type)
            }
            restored.append(item)
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }

    /// Write `text` to the pasteboard, tagged transient + concealed so clipboard
    /// managers ignore it, alongside the plain-string representation we paste.
    private static func writeConcealedText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
    }

    // MARK: - Keystroke

    /// Post a synthetic Cmd+V to the focused application.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
