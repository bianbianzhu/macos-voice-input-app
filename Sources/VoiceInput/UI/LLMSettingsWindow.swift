import AppKit

/// Settings window for the optional LLM refinement feature.
///
/// Privacy/security notes:
/// - The API key lives ONLY in the Keychain (via `KeychainStore`). It is never
///   written to UserDefaults, never logged, and never shown in the status label.
/// - The "API Key" field is a fully clearable `NSSecureTextField`; saving it empty
///   deletes the stored credential.
/// - The app is often in the background, so `show()` explicitly activates it and
///   brings the window forward so the user can type into the fields.
final class LLMSettingsWindowController: NSWindowController {

    static let shared = LLMSettingsWindowController()

    // Field column widths (the window is not resizable, so fixed widths are fine).
    private let labelColumnWidth: CGFloat = 92
    private let fieldColumnWidth: CGFloat = 320

    private var built = false

    private var baseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var statusLabel: NSTextField!
    private var testButton: NSButton!
    private var saveButton: NSButton!

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Build (lazily) and show the settings window, populating fields from
    /// Settings/Keychain. Always called on the main thread.
    func show() {
        buildWindowIfNeeded()
        populateFields()

        // The app may be in the background; without activating, the window would
        // appear but reject keyboard focus and the user could not type.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window construction

    private func buildWindowIfNeeded() {
        guard !built else { return }
        built = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 464, height: 216),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLM Refinement"
        // Singleton controller: keep the window alive after the user closes it so a
        // later `show()` can simply re-order it front.
        window.isReleasedWhenClosed = false

        let content = NSView()

        let baseURLLabel = makeLabel("API Base URL")
        let apiKeyLabel = makeLabel("API Key")
        let modelLabel = makeLabel("Model")

        baseURLField = makeTextField(placeholder: "https://api.openai.com/v1")
        modelField = makeTextField(placeholder: "gpt-4o-mini")

        let secureField = NSSecureTextField()
        secureField.translatesAutoresizingMaskIntoConstraints = false
        secureField.placeholderString = "Stored only in your macOS Keychain"
        secureField.bezelStyle = .roundedBezel
        secureField.cell?.usesSingleLineMode = true
        secureField.cell?.wraps = false
        secureField.cell?.isScrollable = true
        apiKeyField = secureField

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        testButton = NSButton(title: "Test", target: self, action: #selector(testTapped))
        testButton.bezelStyle = .rounded
        testButton.translatesAutoresizingMaskIntoConstraints = false

        saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [testButton, saveButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        for view in [baseURLLabel, apiKeyLabel, modelLabel,
                     baseURLField!, apiKeyField!, modelField!,
                     statusLabel!, buttonRow] {
            content.addSubview(view)
        }

        var constraints: [NSLayoutConstraint] = []

        // Three labeled rows: a fixed, right-aligned label column and a fixed-width field.
        let rows: [(NSTextField, NSTextField)] = [
            (baseURLLabel, baseURLField),
            (apiKeyLabel, apiKeyField),
            (modelLabel, modelField)
        ]
        for (label, field) in rows {
            constraints.append(label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20))
            constraints.append(label.widthAnchor.constraint(equalToConstant: labelColumnWidth))
            constraints.append(label.centerYAnchor.constraint(equalTo: field.centerYAnchor))
            constraints.append(field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12))
            constraints.append(field.widthAnchor.constraint(equalToConstant: fieldColumnWidth))
            // Inequality so the content view's width is exactly large enough (no conflict
            // with the window's managed size).
            constraints.append(content.trailingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 20))
        }

        constraints += [
            baseURLField.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            apiKeyField.topAnchor.constraint(equalTo: baseURLField.bottomAnchor, constant: 12),
            modelField.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 12),

            statusLabel.topAnchor.constraint(equalTo: modelField.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            buttonRow.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ]

        NSLayoutConstraint.activate(constraints)

        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()

        self.window = window
    }

    // MARK: - Field helpers

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.textColor = .labelColor
        return label
    }

    private func makeTextField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    private func populateFields() {
        baseURLField.stringValue = Settings.shared.llmBaseURL
        modelField.stringValue = Settings.shared.llmModel
        // Pre-fill from the Keychain so the user can see a credential exists; clearing
        // the field and saving will delete it.
        apiKeyField.stringValue = KeychainStore.readAPIKey() ?? ""
        setStatus("", color: .secondaryLabelColor)
    }

    /// Reads the CURRENT field values into a config for a live "Test". Trimmed so a
    /// stray trailing space cannot make an otherwise-valid endpoint fail.
    private func currentConfig() -> LLMConfig {
        LLMConfig(
            baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        let urlString = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard LLMRefiner.isValidBaseURL(urlString) else {
            setStatus("Invalid base URL. Remote endpoints must use https:// (localhost may use http).",
                      color: .systemRed)
            return
        }

        Settings.shared.llmBaseURL = urlString
        Settings.shared.llmModel = model
        // Passing the raw field value: an empty/whitespace key deletes the stored
        // credential (handled inside KeychainStore). The key is never logged.
        KeychainStore.saveAPIKey(apiKeyField.stringValue)

        setStatus("Saved.", color: .systemGreen)
    }

    @objc private func testTapped() {
        // Capture field values on the main thread before hopping off to the network.
        let config = currentConfig()

        setStatus("Testing…", color: .secondaryLabelColor)
        testButton.isEnabled = false
        saveButton.isEnabled = false

        Task {
            let result = await LLMRefiner().test(config: config)
            await MainActor.run {
                self.testButton.isEnabled = true
                self.saveButton.isEnabled = true
                switch result {
                case .success(let message):
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
                    self.setStatus("Connection OK" + suffix, color: .systemGreen)
                case .failure(let error):
                    self.setStatus("Test failed — " + self.describe(error), color: .systemRed)
                }
            }
        }
    }

    /// Maps an `LLMError` to a user-facing message. The error never contains the API
    /// key (guaranteed by the refiner contract), so this string is safe to display.
    private func describe(_ error: LLMError) -> String {
        switch error {
        case .notConfigured:
            return "Fill in the base URL, API key, and model."
        case .invalidURL:
            return "The base URL is not valid."
        case .network(let message):
            return message
        case .badResponse:
            return "The server returned an unexpected response."
        case .emptyResponse:
            return "The server returned an empty response."
        }
    }
}
