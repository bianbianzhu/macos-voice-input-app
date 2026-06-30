import Foundation

/// Immutable configuration for a single LLM endpoint call. The `apiKey` is held
/// only for the lifetime of a request and is never persisted or logged here.
struct LLMConfig {
    let baseURL: String
    let apiKey: String
    let model: String
}

enum LLMError: Error {
    case notConfigured
    case invalidURL
    case network(String)
    case badResponse
    case emptyResponse
}

/// Result of `LLMRefiner.refine(_:)`. Distinguishes a genuine refinement from the
/// conservative fall-back to the original transcript, so the caller can surface a
/// brief "inserted raw text" notice ONLY when refinement was actually expected and
/// then failed. Both cases carry the text to inject; neither carries any error
/// detail (privacy: the capsule notice is static copy, never the failure reason).
enum RefineOutcome {
    /// The text the model produced, or the original when refinement was not even
    /// attempted (empty / not configured / no key — these are gated upstream and
    /// are NOT user-facing failures, so they must stay silent).
    case refined(String)
    /// Refinement was attempted but failed or was discarded, so the ORIGINAL
    /// transcript is being returned. The caller should inject it and inform the user.
    case fellBack(String)

    /// The text to inject, regardless of outcome.
    var text: String {
        switch self {
        case .refined(let value), .fellBack(let value): return value
        }
    }

    /// Whether the result is the raw transcript after a failed/discarded refinement.
    var fellBack: Bool {
        switch self {
        case .refined: return false
        case .fellBack: return true
        }
    }
}

/// Refines speech-to-text output via an OpenAI-compatible `/chat/completions`
/// endpoint. The design is intentionally conservative: any failure path returns
/// the ORIGINAL transcript unchanged so a flaky network or a chatty model can
/// never corrupt or drop the user's words.
///
/// Privacy: the API key is read from the Keychain only at call time, sent solely
/// in the `Authorization` header, and never printed, logged, or embedded in any
/// returned error message.
final class LLMRefiner {

    init() {}

    // MARK: - Prompts

    /// Highly constrained correction prompt. The model is told to touch nothing
    /// except clear speech-recognition slips, and to echo correct input verbatim.
    private static let systemPrompt = """
    You are a transcription correction assistant for speech-to-text output. The \
    text may be primarily Chinese and may also contain words in other languages.

    Your ONLY job is to fix obvious speech-recognition errors:
    1. Chinese homophone mistakes — characters that sound like the intended word \
    but are wrong in context.
    2. English (or other) technical terms that were mis-transcribed into Chinese \
    characters that merely sound like the term, e.g. 配森 → Python, 杰森 → JSON, \
    瑞克特 → React, 哥德 → Go, 多克 → Docker.

    STRICT RULES:
    - Do NOT rewrite, paraphrase, polish, summarize, reorder, translate, or \
    change the tone of the text.
    - Do NOT add or remove any content that is already correct.
    - Do NOT add punctuation, quotation marks, explanations, or commentary.
    - Preserve the original language(s); never translate between languages.
    - If the input already looks correct, return it exactly as it is.

    Output ONLY the corrected text, with nothing before or after it.
    """

    /// Minimal prompt used by the Settings "Test" button. Keeps the request tiny.
    private static let testSystemPrompt = """
    You are a connectivity test endpoint. Reply with the single word: OK
    """

    // MARK: - URL validation

    /// Validates a base URL string per the security policy:
    /// - remote (non-loopback) hosts MUST use https
    /// - loopback hosts (localhost / 127.0.0.1 / ::1) MAY use http
    static func isValidBaseURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else {
            return false
        }

        switch scheme {
        case "https":
            return true
        case "http":
            // Plaintext is acceptable only to a loopback address.
            return isLoopbackHost(host)
        default:
            return false
        }
    }

    /// True when `host` refers to the local machine. Covers `localhost`, the IPv6
    /// loopback `::1` (bracketed or bare), and the entire 127.0.0.0/8 range.
    ///
    /// The IPv4 check parses a strict dotted-quad rather than matching a "127."
    /// prefix, so deceptive remote hostnames like `127.evil.com` or
    /// `127.0.0.1.example.com` are correctly rejected (and thus barred from http).
    private static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h == "[::1]" {
            return true
        }
        // IPv4 loopback: exactly four numeric octets (0...255) with first octet 127.
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var parsed: [Int] = []
        for octet in octets {
            guard !octet.isEmpty,
                  octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(octet), value >= 0, value <= 255 else {
                return false
            }
            parsed.append(value)
        }
        return parsed[0] == 127
    }

    /// True if base URL + model (from Settings) and the Keychain key are all
    /// present and the URL passes `isValidBaseURL`.
    static func isConfigured() -> Bool {
        let baseURL = Settings.shared.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = Settings.shared.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty, isValidBaseURL(baseURL) else {
            return false
        }
        guard let key = KeychainStore.readAPIKey(),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    // MARK: - Public API

    /// Refines `text`, returning the original on ANY failure or implausible result.
    /// The `RefineOutcome` lets the caller tell a real refinement apart from a
    /// fall-back so it can surface a brief notice; the text itself is unchanged.
    func refine(_ text: String) async -> RefineOutcome {
        // Nothing meaningful to refine. Not an attempt, so stay silent.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refined(text)
        }
        // Not configured / no key: gated upstream and not user-facing failures.
        guard LLMRefiner.isConfigured() else { return .refined(text) }
        guard let apiKey = KeychainStore.readAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refined(text)
        }

        let config = LLMConfig(
            baseURL: Settings.shared.llmBaseURL,
            apiKey: apiKey,
            model: Settings.shared.llmModel
        )

        let result = await performChat(
            config: config,
            systemPrompt: LLMRefiner.systemPrompt,
            userContent: text
        )

        switch result {
        case .failure:
            // Conservative: never surface an error to the user's text stream, but
            // signal the fall-back so the caller can show an informational notice.
            return .fellBack(text)
        case .success(let refined):
            // Length sanity: a sane correction is roughly the same length. If the
            // model expanded the text dramatically it likely added commentary or
            // hallucinated, so discard it. No charset filtering (this is CJK-first).
            if refined.count > max(40, text.count * 3) {
                return .fellBack(text)
            }
            return .refined(refined)
        }
    }

    /// Used by the Settings "Test" button. Sends a tiny request with the GIVEN
    /// config. Any returned error is key-free.
    func test(config: LLMConfig) async -> Result<String, LLMError> {
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURL.isEmpty, !model.isEmpty, !apiKey.isEmpty else {
            return .failure(.notConfigured)
        }
        guard LLMRefiner.isValidBaseURL(baseURL) else {
            return .failure(.invalidURL)
        }

        let probe = LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
        let result = await performChat(
            config: probe,
            systemPrompt: LLMRefiner.testSystemPrompt,
            userContent: "ping"
        )

        switch result {
        case .success(let content):
            // Short, key-free confirmation: a snippet of the model's reply. The
            // caller prefixes its own "Connection OK", so we don't repeat it here.
            let snippet = content.count > 60 ? String(content.prefix(60)) + "…" : content
            return .success(snippet)
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Networking

    /// Performs one chat completion. Returns the trimmed assistant content on
    /// success. Errors never contain the API key.
    private func performChat(
        config: LLMConfig,
        systemPrompt: String,
        userContent: String
    ) async -> Result<String, LLMError> {
        guard LLMRefiner.isValidBaseURL(config.baseURL),
              let url = LLMRefiner.endpointURL(for: config.baseURL) else {
            return .failure(.invalidURL)
        }

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return .failure(.badResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.badResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                // Status code only — never the body, which could echo the request.
                return .failure(.network("HTTP \(http.statusCode)"))
            }
            guard let content = LLMRefiner.parseContent(from: data) else {
                return .failure(.badResponse)
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure(.emptyResponse)
            }
            return .success(trimmed)
        } catch {
            // URLError descriptions are about connectivity and carry no secret.
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Builds `<baseURL>/chat/completions`, trimming any trailing slashes.
    private static func endpointURL(for baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/chat/completions")
    }

    /// Extracts `choices[0].message.content` from an OpenAI-compatible response.
    private static func parseContent(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let json = object as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }
}
