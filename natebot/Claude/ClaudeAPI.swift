import Foundation

// MARK: - Claude API Client (raw HTTP, no SDK — Swift native)

class ClaudeAPI {
    let apiKey: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Request / Response types

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Message]
        let thinking: ThinkingConfig?

        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct ThinkingConfig: Encodable {
            let type: String  // "adaptive"
        }
    }

    private struct ResponseBody: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        let content: [ContentBlock]

        struct ErrorBody: Decodable {
            struct APIError: Decodable {
                let message: String
            }
            let error: APIError
        }
    }

    // MARK: - Public API

    enum ClaudeError: Error, LocalizedError {
        case apiError(String)
        case noTextContent
        case networkError(Error)
        case decodingError(Error)

        var errorDescription: String? {
            switch self {
            case .apiError(let msg): return "Claude API error: \(msg)"
            case .noTextContent: return "Claude returned no text content"
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .decodingError(let e): return "Decode error: \(e.localizedDescription)"
            }
        }
    }

    /// Call Claude with a system prompt and a single user message.
    /// - Parameter useThinking: Set true for reasoning-heavy tasks (uses adaptive thinking).
    func call(
        system: String,
        userMessage: String,
        maxTokens: Int = 4096,
        useThinking: Bool = false,
        completion: @escaping (Result<String, ClaudeError>) -> Void
    ) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 90

        let body = RequestBody(
            model: "claude-opus-4-6",
            max_tokens: maxTokens,
            system: system,
            messages: [RequestBody.Message(role: "user", content: userMessage)],
            thinking: useThinking ? RequestBody.ThinkingConfig(type: "adaptive") : nil
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(.decodingError(error)))
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(.networkError(error)))
                return
            }
            guard let data = data else {
                completion(.failure(.apiError("Empty response from server")))
                return
            }

            // Try to decode success response
            if let response = try? JSONDecoder().decode(ResponseBody.self, from: data) {
                let text = response.content.first(where: { $0.type == "text" })?.text ?? ""
                completion(.success(text))
                return
            }

            // Try to decode error response
            if let errBody = try? JSONDecoder().decode(ResponseBody.ErrorBody.self, from: data) {
                completion(.failure(.apiError(errBody.error.message)))
                return
            }

            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            completion(.failure(.apiError("Unexpected response: \(raw.prefix(200))")))
        }.resume()
    }
}

// MARK: - JSON Extraction Helpers (shared utility)

extension String {
    /// Extract the first JSON object {...} from a string that may have surrounding text.
    func extractJSONObject() -> String? {
        var s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code fences
        if s.hasPrefix("```") {
            let lines = s.components(separatedBy: "\n")
            s = lines.dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        guard let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}") else { return nil }
        return String(s[start...end])
    }

    /// Extract the first JSON array [...] from a string that may have surrounding text.
    func extractJSONArray() -> String? {
        var s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            let lines = s.components(separatedBy: "\n")
            s = lines.dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        guard let start = s.firstIndex(of: "["),
              let end = s.lastIndex(of: "]") else { return nil }
        return String(s[start...end])
    }
}

// MARK: - Date parsing helper

extension Date {
    /// Parse an ISO8601-like date string from Claude's responses, tolerating missing timezone.
    static func fromClaudeString(_ s: String) -> Date? {
        // Standard ISO8601
        if let d = ISO8601DateFormatter().date(from: s) { return d }

        // Without timezone (e.g. "2026-03-15T14:00:00")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
