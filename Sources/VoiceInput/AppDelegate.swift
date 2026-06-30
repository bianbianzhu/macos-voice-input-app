import AppKit
import ApplicationServices

/// Menu-bar entry point. Owns the global Fn-key monitor and the app coordinator,
/// builds the status-bar menu, and requests the permissions the app needs
/// (Speech/Microphone + Accessibility) at launch.
///
/// Privacy note: nothing here ever logs, prints, or persists audio, transcribed
/// text, keystrokes, or the API key — it only reads non-secret toggles from
/// `Settings` and delegates the secret-handling to `KeychainStore`/`LLMRefiner`.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // Retained so the menu-bar item and the event tap stay alive for the
    // lifetime of the app.
    private var statusItem: NSStatusItem?
    private let coordinator = AppCoordinator()
    private let fnMonitor = FnKeyMonitor()

    // References to the dynamic menu items so they can be refreshed when the
    // menu re-opens (the language submenu is rebuilt fresh; toggles re-checked).
    private var languageMenuItem: NSMenuItem?
    private var onDeviceItem: NSMenuItem?
    private var soundCuesItem: NSMenuItem?
    private var llmEnableItem: NSMenuItem?

    // Reflects whether the Fn monitor is live, and the timer that waits for the
    // user to grant Accessibility so the monitor can start without a relaunch.
    private var statusStateItem: NSMenuItem?
    private var accessibilityPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        wireMonitor()
        requestPermissions()
    }

    /// A minimal main menu. The Edit menu is the important part: it gives the
    /// Preferences and LLM-settings text fields working Cut/Copy/Paste/Select-All
    /// keyboard shortcuts (e.g. ⌘V to paste an API key), which a `.regular` app
    /// only gets from a populated Edit menu in the responder chain.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Preferences…",
                        action: #selector(openPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Voice Input",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Voice Input",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform",
                                accessibilityDescription: "Voice Input")
            image?.isTemplate = true
            button.image = image
        }
        let menu = buildMenu()
        // Recompute readiness each time the menu opens so the status line never
        // shows a stale "ready" if Accessibility was revoked after the tap started.
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // We manage enabled state explicitly so the title item stays greyed out
        // and every action item stays live.
        menu.autoenablesItems = false

        // Non-actionable hint, shown disabled.
        let title = NSMenuItem(title: "Hold Fn to dictate", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        // Live readiness indicator (updated when the Fn monitor starts/stops).
        let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        statusStateItem = state
        refreshMonitorStateItem()

        menu.addItem(.separator())

        // Language submenu (single mutually-exclusive control: Auto + fixed langs).
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = makeLanguageMenu()
        menu.addItem(languageItem)
        languageMenuItem = languageItem

        // On-device recognition toggle.
        let onDevice = NSMenuItem(title: "On-device Recognition",
                                  action: #selector(toggleOnDevice(_:)),
                                  keyEquivalent: "")
        onDevice.target = self
        onDevice.state = Settings.shared.onDeviceRecognition ? .on : .off
        menu.addItem(onDevice)
        onDeviceItem = onDevice

        // Optional audio cues (start / stop / done) toggle.
        let soundCues = NSMenuItem(title: "Sound Cues",
                                   action: #selector(toggleSoundCues(_:)),
                                   keyEquivalent: "")
        soundCues.target = self
        soundCues.state = Settings.shared.soundCuesEnabled ? .on : .off
        menu.addItem(soundCues)
        soundCuesItem = soundCues

        // LLM refinement submenu (Enable toggle + Settings…).
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        llmMenu.autoenablesItems = false

        let enable = NSMenuItem(title: "Enable",
                                action: #selector(toggleLLM(_:)),
                                keyEquivalent: "")
        enable.target = self
        enable.state = Settings.shared.llmEnabled ? .on : .off
        llmMenu.addItem(enable)
        llmEnableItem = enable

        let llmSettings = NSMenuItem(title: "Settings…",
                                     action: #selector(openLLMSettings(_:)),
                                     keyEquivalent: "")
        llmSettings.target = self
        llmMenu.addItem(llmSettings)

        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        // Preferences window (also reachable from the Dock icon).
        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(openPreferences(_:)),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Voice Input",
                              action: #selector(quit(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// Builds the language chooser fresh: "Auto — follow input source" plus the
    /// five fixed languages, with a checkmark on the active selection. Used by both
    /// the menu-bar submenu and the Dock menu, so it reads current state each time.
    private func makeLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let auto = Settings.shared.languageFollowsInputSource
        let current = Settings.shared.recognitionLanguage

        let autoItem = NSMenuItem(title: "Auto — follow input source",
                                  action: #selector(selectLanguage(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = PreferencesWindowController.autoTag
        autoItem.state = auto ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        for language in Settings.supportedLanguages {
            let item = NSMenuItem(title: language.name,
                                  action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.code
            item.state = (!auto && language.code == current) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Menu actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if value == PreferencesWindowController.autoTag {
            Settings.shared.languageFollowsInputSource = true
        } else {
            Settings.shared.languageFollowsInputSource = false
            Settings.shared.recognitionLanguage = value
        }
    }

    @objc private func openPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.show()
    }

    @objc private func toggleOnDevice(_ sender: NSMenuItem) {
        let newValue = !Settings.shared.onDeviceRecognition
        Settings.shared.onDeviceRecognition = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleSoundCues(_ sender: NSMenuItem) {
        let newValue = !Settings.shared.soundCuesEnabled
        Settings.shared.soundCuesEnabled = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleLLM(_ sender: NSMenuItem) {
        let newValue = !Settings.shared.llmEnabled
        Settings.shared.llmEnabled = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func openLLMSettings(_ sender: NSMenuItem) {
        LLMSettingsWindowController.shared.show()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - Wiring

    private func wireMonitor() {
        // FnKeyMonitor documents these callbacks as firing on the main thread,
        // and AppCoordinator's handlers are main-thread methods, so no hop here.
        fnMonitor.onFnDown = { [weak self] in
            self?.coordinator.handleFnDown()
        }
        fnMonitor.onFnUp = { [weak self] in
            self?.coordinator.handleFnUp()
        }
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Speech + Microphone authorization. The result is consumed by the speech
        // subsystem on demand; we don't need to act on it here.
        SpeechTranscriber.requestAuthorization { _ in }

        // Ask the system to surface the Accessibility prompt at launch. This is the
        // permission the global Fn-key event tap and text injection depend on.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        // Install the global event tap. If it starts, we're ready.
        if fnMonitor.start() {
            refreshMonitorStateItem()
            return
        }

        // Not trusted yet — very common right after a rebuild, because ad-hoc
        // re-signing changes the app's code signature and invalidates the previous
        // Accessibility grant. Guide the user, then poll so the monitor starts the
        // instant access is granted, with no relaunch required.
        if !trusted {
            presentAccessibilityAlert()
        }
        startAccessibilityPolling()
        refreshMonitorStateItem()
    }

    /// Poll for Accessibility trust and start the Fn monitor the moment it is
    /// granted, so the user never has to quit and relaunch after toggling access.
    private func startAccessibilityPolling() {
        guard accessibilityPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard AXIsProcessTrusted() else { return }
            if self.fnMonitor.start() {
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.refreshMonitorStateItem()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPollTimer = timer
    }

    /// Update the disabled status line in the menu to reflect *live* readiness.
    /// Readiness requires both an installed tap AND current Accessibility trust, so
    /// the line can't keep asserting "ready" after access is revoked mid-session.
    private func refreshMonitorStateItem() {
        let ready = fnMonitor.isActive && AXIsProcessTrusted()
        statusStateItem?.title = ready
            ? "✓ Fn dictation ready"
            : "⚠︎ Waiting for Accessibility permission…"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // If Accessibility was revoked while running, the tap is dead but the
        // monitor still holds a (now useless) port. Drop it and resume polling so
        // the monitor automatically recovers if access is granted again.
        if fnMonitor.isActive && !AXIsProcessTrusted() {
            fnMonitor.stop()
            startAccessibilityPolling()
        }
        refreshMonitorStateItem()

        // Re-sync the dynamic items so a change made elsewhere (Preferences window,
        // Dock menu) is reflected here.
        languageMenuItem?.submenu = makeLanguageMenu()
        onDeviceItem?.state = Settings.shared.onDeviceRecognition ? .on : .off
        soundCuesItem?.state = Settings.shared.soundCuesEnabled ? .on : .off
        llmEnableItem?.state = Settings.shared.llmEnabled ? .on : .off
    }

    // MARK: - Dock integration

    /// Right-click ▸ Dock menu: quick language switch + Preferences (Quit is added
    /// by the system). Built fresh each time so it always reflects current state.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        language.submenu = makeLanguageMenu()
        menu.addItem(language)

        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(openPreferences(_:)), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
        return menu
    }

    /// Clicking the Dock icon with no open window opens Preferences.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            PreferencesWindowController.shared.show()
        }
        return true
    }

    private func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Access Needed"
        alert.informativeText = "Voice Input needs Accessibility access to detect the Fn key and insert text into the focused field.\n\nOpen System Settings ▸ Privacy & Security ▸ Accessibility and enable Voice Input. Dictation activates automatically once access is granted — no relaunch needed."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        // The app may be in the background, so activate it to bring the alert front.
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
