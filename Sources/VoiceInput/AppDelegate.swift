import AppKit
import ApplicationServices

/// Menu-bar entry point. Owns the global Fn-key monitor and the app coordinator,
/// builds the status-bar menu, and requests the permissions the app needs
/// (Speech/Microphone + Accessibility) at launch.
///
/// Privacy note: nothing here ever logs, prints, or persists audio, transcribed
/// text, keystrokes, or the API key — it only reads non-secret toggles from
/// `Settings` and delegates the secret-handling to `KeychainStore`/`LLMRefiner`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Retained so the menu-bar item and the event tap stay alive for the
    // lifetime of the app.
    private var statusItem: NSStatusItem?
    private let coordinator = AppCoordinator()
    private let fnMonitor = FnKeyMonitor()

    // References to the dynamic menu items so checkmarks can be refreshed
    // in place when a toggle changes.
    private var languageItems: [NSMenuItem] = []
    private var onDeviceItem: NSMenuItem?
    private var llmEnableItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        wireMonitor()
        requestPermissions()
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
        item.menu = buildMenu()
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

        menu.addItem(.separator())

        // Language submenu.
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        languageItems.removeAll()
        let currentLanguage = Settings.shared.recognitionLanguage
        for language in Settings.supportedLanguages {
            let menuItem = NSMenuItem(title: language.name,
                                      action: #selector(selectLanguage(_:)),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = language.code
            menuItem.state = (language.code == currentLanguage) ? .on : .off
            languageMenu.addItem(menuItem)
            languageItems.append(menuItem)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        // On-device recognition toggle.
        let onDevice = NSMenuItem(title: "On-device Recognition",
                                  action: #selector(toggleOnDevice(_:)),
                                  keyEquivalent: "")
        onDevice.target = self
        onDevice.state = Settings.shared.onDeviceRecognition ? .on : .off
        menu.addItem(onDevice)
        onDeviceItem = onDevice

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

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Voice Input",
                              action: #selector(quit(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Menu actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Settings.shared.recognitionLanguage = code
        for item in languageItems {
            item.state = ((item.representedObject as? String) == code) ? .on : .off
        }
    }

    @objc private func toggleOnDevice(_ sender: NSMenuItem) {
        let newValue = !Settings.shared.onDeviceRecognition
        Settings.shared.onDeviceRecognition = newValue
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
        _ = AXIsProcessTrustedWithOptions(options)

        // Install the global event tap. If it can't be created the user almost
        // certainly hasn't granted Accessibility yet — guide them to System Settings.
        if !fnMonitor.start() {
            presentAccessibilityAlert()
        }
    }

    private func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Access Needed"
        alert.informativeText = "Voice Input needs Accessibility access to detect the Fn key and insert text into the focused field.\n\nOpen System Settings ▸ Privacy & Security ▸ Accessibility, enable Voice Input, then relaunch the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        // As an accessory (menu-bar-only) app we must activate to bring the alert
        // to the front.
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
