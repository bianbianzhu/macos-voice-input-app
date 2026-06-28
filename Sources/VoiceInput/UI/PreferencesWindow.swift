import AppKit

/// The app's main settings window, reachable from the Dock icon (click or
/// right-click ▸ Preferences) so it never depends on the menu-bar icon being
/// visible. Hosts the single mutually-exclusive dictation-language control plus
/// the on-device and LLM toggles.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    /// Sentinel represented-object for the "Auto" language menu entry.
    static let autoTag = "auto"

    private var built = false

    private var languagePopUp: NSPopUpButton!
    private var onDeviceCheckbox: NSButton!
    private var llmEnabledCheckbox: NSButton!

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Build (lazily) and show the window, syncing every control to current
    /// settings. Always called on the main thread.
    func show() {
        buildWindowIfNeeded()
        syncControls()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    private func buildWindowIfNeeded() {
        guard !built else { return }
        built = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Input Preferences"
        window.isReleasedWhenClosed = false
        // Re-sync whenever the window regains focus, so a change made from the menu
        // bar or Dock menu while it was open is reflected.
        window.delegate = self

        let content = NSView()

        let languageLabel = makeLabel("Dictation Language")
        languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopUp.translatesAutoresizingMaskIntoConstraints = false
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChanged)
        // "Auto" first, then the fixed languages — one mutually-exclusive control.
        let autoItem = NSMenuItem(title: "Auto — follow input source", action: nil, keyEquivalent: "")
        autoItem.representedObject = PreferencesWindowController.autoTag
        languagePopUp.menu?.addItem(autoItem)
        languagePopUp.menu?.addItem(.separator())
        for language in Settings.supportedLanguages {
            let item = NSMenuItem(title: language.name, action: nil, keyEquivalent: "")
            item.representedObject = language.code
            languagePopUp.menu?.addItem(item)
        }

        let languageHint = makeHint("Auto picks the recognition language from whatever input source is active when you start dictating.")

        onDeviceCheckbox = NSButton(checkboxWithTitle: "On-device recognition (private, offline)",
                                    target: self, action: #selector(onDeviceToggled))
        onDeviceCheckbox.translatesAutoresizingMaskIntoConstraints = false

        llmEnabledCheckbox = NSButton(checkboxWithTitle: "Enable LLM refinement",
                                      target: self, action: #selector(llmToggled))
        llmEnabledCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let llmSettingsButton = NSButton(title: "LLM Settings…", target: self, action: #selector(openLLMSettings))
        llmSettingsButton.bezelStyle = .rounded
        llmSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        for view in [languageLabel, languagePopUp!, languageHint,
                     onDeviceCheckbox!, llmEnabledCheckbox!, llmSettingsButton] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            languageLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            languageLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            languagePopUp.leadingAnchor.constraint(equalTo: languageLabel.trailingAnchor, constant: 12),
            languagePopUp.centerYAnchor.constraint(equalTo: languageLabel.centerYAnchor),
            languagePopUp.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            languagePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),

            languageHint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            languageHint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            languageHint.topAnchor.constraint(equalTo: languageLabel.bottomAnchor, constant: 8),

            onDeviceCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            onDeviceCheckbox.topAnchor.constraint(equalTo: languageHint.bottomAnchor, constant: 18),

            llmEnabledCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            llmEnabledCheckbox.topAnchor.constraint(equalTo: onDeviceCheckbox.bottomAnchor, constant: 14),

            llmSettingsButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            llmSettingsButton.topAnchor.constraint(equalTo: llmEnabledCheckbox.bottomAnchor, constant: 14),
            llmSettingsButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])

        window.contentView = content
        window.setContentSize(NSSize(width: 440, height: 230))
        window.center()
        self.window = window
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makeHint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        return label
    }

    // MARK: - Sync

    private func syncControls() {
        // Select "Auto" or the fixed language, reflecting the single source of truth.
        if Settings.shared.languageFollowsInputSource {
            selectLanguageItem(matching: PreferencesWindowController.autoTag)
        } else {
            selectLanguageItem(matching: Settings.shared.recognitionLanguage)
        }
        onDeviceCheckbox.state = Settings.shared.onDeviceRecognition ? .on : .off
        llmEnabledCheckbox.state = Settings.shared.llmEnabled ? .on : .off
    }

    private func selectLanguageItem(matching value: String) {
        for item in languagePopUp.itemArray where (item.representedObject as? String) == value {
            languagePopUp.select(item)
            return
        }
    }

    // MARK: - Actions

    @objc private func languageChanged() {
        guard let value = languagePopUp.selectedItem?.representedObject as? String else { return }
        if value == PreferencesWindowController.autoTag {
            Settings.shared.languageFollowsInputSource = true
        } else {
            Settings.shared.languageFollowsInputSource = false
            Settings.shared.recognitionLanguage = value
        }
    }

    @objc private func onDeviceToggled() {
        Settings.shared.onDeviceRecognition = (onDeviceCheckbox.state == .on)
    }

    @objc private func llmToggled() {
        Settings.shared.llmEnabled = (llmEnabledCheckbox.state == .on)
    }

    @objc private func openLLMSettings() {
        LLMSettingsWindowController.shared.show()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        syncControls()
    }
}
