import Foundation
import Carbon

/// Maps the *current* keyboard input source to a speech-recognition locale, so
/// dictation can automatically follow whatever language the user is typing in
/// (e.g. tap Fn to switch to English → hold Fn → dictate in English).
///
/// Reads only public Text Input Source metadata; it never inspects keystrokes.
enum InputSourceLanguage {

    /// Best-effort BCP-47 recognition locale for the current input source.
    /// Returns `fallback` when the source can't be confidently mapped, so we never
    /// guess a wrong language and silently mis-transcribe.
    static func currentRecognitionLanguage(fallback: String) -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return fallback
        }

        // Preferred signal: the language(s) the source declares it inputs
        // (e.g. "zh-Hans", "ja", "en"). First entry is the primary language.
        if let language = primaryLanguage(of: source), let mapped = map(language: language) {
            return mapped
        }

        // Fallback signal: the source ID string, for input modes that don't report
        // a usable primary language (e.g. some third-party engines).
        if let id = sourceID(of: source), let mapped = mapBySourceID(id) {
            return mapped
        }

        return fallback
    }

    // MARK: - Property readers

    private static func primaryLanguage(of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let array = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as NSArray
        return array.firstObject as? String
    }

    private static func sourceID(of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    // MARK: - Mapping

    /// Map an ISO language tag reported by an input source to a recognition locale.
    /// A bare, region-less "zh" is treated as ambiguous and deferred to the source
    /// ID so Traditional vs Simplified can be told apart.
    private static func map(language: String) -> String? {
        let l = language.lowercased()
        if l.hasPrefix("zh-hant") || l.hasPrefix("zh_hant") { return "zh-TW" }
        if l.hasPrefix("zh-hans") || l.hasPrefix("zh_hans") { return "zh-CN" }
        if l == "zh" { return nil }                      // ambiguous — let the ID decide
        if l.hasPrefix("zh") { return "zh-CN" }          // zh-CN, zh-SG, …
        if l.hasPrefix("ja") { return "ja-JP" }
        if l.hasPrefix("ko") { return "ko-KR" }
        if l.hasPrefix("en") { return "en-US" }
        return nil
    }

    /// Map an input-source ID string to a recognition locale. Traditional Chinese
    /// is checked before Simplified so a "pinyin" substring can't misroute it.
    /// Plain keyboard layouts (Australian, ABC, US, …) already report "en" via the
    /// language signal, so there is deliberately NO layout catch-all here: an
    /// unrecognized source returns nil and the caller uses the configured fallback
    /// rather than guessing a wrong language.
    private static func mapBySourceID(_ id: String) -> String? {
        let s = id.lowercased()
        if s.contains("tcim") || s.contains("zhuyin") || s.contains("cangjie")
            || s.contains("pinyin.tc") || s.contains("trad") { return "zh-TW" }
        if s.contains("scim") || s.contains("itabc") || s.contains("pinyin")
            || s.contains("wubi") || s.contains("shuangpin") || s.contains("simp") { return "zh-CN" }
        if s.contains("japanese") || s.contains("kotoeri") { return "ja-JP" }
        if s.contains("korean") || s.contains("hangul") || s.contains("gureum") { return "ko-KR" }
        return nil
    }
}
