import Foundation

/// UserDefaults-backed application settings.
///
/// IMPORTANT: the LLM API key is intentionally NOT stored here. It lives only in
/// the macOS Keychain (see `KeychainStore`). Nothing in this type is secret.
final class Settings {

    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let recognitionLanguage = "recognitionLanguage"
        static let onDeviceRecognition = "onDeviceRecognition"
        static let llmEnabled = "llmEnabled"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
    }

    private init() {
        // Defaults: Simplified Chinese works out of the box; on-device recognition
        // is on by default for privacy; LLM refinement is opt-in.
        defaults.register(defaults: [
            Key.recognitionLanguage: "zh-CN",
            Key.onDeviceRecognition: true,
            Key.llmEnabled: false,
            Key.llmBaseURL: "",
            Key.llmModel: ""
        ])
    }

    /// BCP-47 locale identifier used for speech recognition. Default "zh-CN".
    var recognitionLanguage: String {
        get { defaults.string(forKey: Key.recognitionLanguage) ?? "zh-CN" }
        set { defaults.set(newValue, forKey: Key.recognitionLanguage) }
    }

    /// Whether to force on-device speech recognition (privacy).
    var onDeviceRecognition: Bool {
        get { defaults.bool(forKey: Key.onDeviceRecognition) }
        set { defaults.set(newValue, forKey: Key.onDeviceRecognition) }
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Key.llmEnabled) }
        set { defaults.set(newValue, forKey: Key.llmEnabled) }
    }

    var llmBaseURL: String {
        get { defaults.string(forKey: Key.llmBaseURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.llmBaseURL) }
    }

    var llmModel: String {
        get { defaults.string(forKey: Key.llmModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.llmModel) }
    }

    /// Languages offered in the menu. `code` is a BCP-47 identifier suitable for
    /// `SFSpeechRecognizer(locale:)`; `name` is the menu display string.
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-CN", "简体中文 (Simplified Chinese)"),
        ("zh-TW", "繁體中文 (Traditional Chinese)"),
        ("en-US", "English"),
        ("ja-JP", "日本語 (Japanese)"),
        ("ko-KR", "한국어 (Korean)")
    ]
}

/// Minimal, language-aware UI strings for the floating capsule. Picks Chinese,
/// Japanese, or Korean copy based on the active recognition language, English
/// otherwise. Keeps the HUD feeling native without a full localization stack.
enum L10n {
    private static var lang: String { Settings.shared.recognitionLanguage }

    static var listening: String {
        if lang.hasPrefix("zh") { return "聆听中…" }
        if lang.hasPrefix("ja") { return "聞き取り中…" }
        if lang.hasPrefix("ko") { return "듣는 중…" }
        return "Listening…"
    }

    static var refining: String {
        if lang.hasPrefix("zh") { return "优化中…" }
        if lang.hasPrefix("ja") { return "整えています…" }
        if lang.hasPrefix("ko") { return "다듬는 중…" }
        return "Refining…"
    }
}
