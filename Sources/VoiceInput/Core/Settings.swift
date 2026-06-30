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
        static let languageFollowsInputSource = "languageFollowsInputSource"
        static let onDeviceRecognition = "onDeviceRecognition"
        static let llmEnabled = "llmEnabled"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let soundCuesEnabled = "soundCuesEnabled"
    }

    private init() {
        // Defaults: dictation language follows the current input source out of the
        // box (so it "just works" as the user switches input methods); Simplified
        // Chinese is the fixed-mode fallback; on-device recognition is on for
        // privacy; LLM refinement is opt-in.
        defaults.register(defaults: [
            Key.recognitionLanguage: "zh-CN",
            Key.languageFollowsInputSource: true,
            Key.onDeviceRecognition: true,
            Key.llmEnabled: false,
            Key.llmBaseURL: "",
            Key.llmModel: "",
            Key.soundCuesEnabled: false
        ])
    }

    /// BCP-47 locale identifier used for speech recognition in *fixed* mode, and as
    /// the fallback when `languageFollowsInputSource` is on but the current input
    /// source can't be mapped. Default "zh-CN".
    var recognitionLanguage: String {
        get { defaults.string(forKey: Key.recognitionLanguage) ?? "zh-CN" }
        set { defaults.set(newValue, forKey: Key.recognitionLanguage) }
    }

    /// When true (the default), the dictation language automatically follows the
    /// current keyboard input source. When false, `recognitionLanguage` is used.
    /// These are the two states of a single mutually-exclusive "language" control,
    /// so they can never conflict.
    var languageFollowsInputSource: Bool {
        get { defaults.bool(forKey: Key.languageFollowsInputSource) }
        set { defaults.set(newValue, forKey: Key.languageFollowsInputSource) }
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

    /// Optional audio cues (start / stop / done) for eyes-free feedback. Off by
    /// default so the app stays silent unless the user opts in. See `SoundCue`.
    var soundCuesEnabled: Bool {
        get { defaults.bool(forKey: Key.soundCuesEnabled) }
        set { defaults.set(newValue, forKey: Key.soundCuesEnabled) }
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

/// Minimal, language-aware UI strings for the floating capsule. The language is
/// passed in (the locale the recognizer is actually using for this dictation —
/// which in Auto mode may differ from the fixed setting), so the HUD copy always
/// matches what's being transcribed. Keeps the HUD native without a full L10n stack.
enum L10n {
    static func listening(_ lang: String) -> String {
        if lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-Hant") { return "聆聽中…" }
        if lang.hasPrefix("zh") { return "聆听中…" }
        if lang.hasPrefix("ja") { return "聞き取り中…" }
        if lang.hasPrefix("ko") { return "듣는 중…" }
        return "Listening…"
    }

    static func refining(_ lang: String) -> String {
        if lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-Hant") { return "優化中…" }
        if lang.hasPrefix("zh") { return "优化中…" }
        if lang.hasPrefix("ja") { return "整えています…" }
        if lang.hasPrefix("ko") { return "다듬는 중…" }
        return "Refining…"
    }
}
