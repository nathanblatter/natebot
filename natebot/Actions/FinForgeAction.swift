import Foundation

// MARK: - FinForgeAction
// Integrates with the FinForge API to deliver financial alerts, briefings,
// portfolio data, predictions, and goal updates via iMessage.

class FinForgeAction {
    let baseURL: String   // "http://localhost:8001/api/v1/natebot"
    let apiKey: String
    let reply: ReplyAction
    let log: ActivityLog
    let pollInterval: TimeInterval

    init(config: FinForgeConfig, reply: ReplyAction, log: ActivityLog) {
        // Normalize: strip trailing slash, append /natebot if needed
        var url = config.apiUrl
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if !url.hasSuffix("/natebot") { url += "/natebot" }
        self.baseURL = url
        self.apiKey = config.apiKey
        self.reply = reply
        self.log = log
        self.pollInterval = TimeInterval(config.pollIntervalSeconds)
    }

    // MARK: - Poll pending notifications (called by ProactiveMonitor)

    func pollPending(completion: @escaping () -> Void) {
        get(path: "/natebot/pending") { [weak self] data in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else {
                completion()
                return
            }

            let count = messages.count
            for msg in messages {
                if let text = msg["text"] as? String {
                    self.reply.send(text)
                }
            }

            if count > 0 {
                self.log.append(from: "finforge", message: "poll",
                                action: "finforge_poll", result: "ok",
                                reply: "delivered \(count) message(s)")
            }
            completion()
        }
    }

    // MARK: - On-demand fetches

    func briefing(completion: @escaping (String) -> Void) {
        getText(path: "/natebot/imessage/briefing", fallback: "Could not fetch financial briefing.", completion: completion)
    }

    func portfolio(completion: @escaping (String) -> Void) {
        getText(path: "/natebot/imessage/portfolio", fallback: "Could not fetch portfolio.", completion: completion)
    }

    func predict(symbol: String, completion: @escaping (String) -> Void) {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        getText(path: "/natebot/imessage/predict/\(encoded)", fallback: "Could not fetch prediction.", completion: completion)
    }

    func goals(completion: @escaping (String) -> Void) {
        getText(path: "/natebot/imessage/goals", fallback: "Could not fetch financial goals.", completion: completion)
    }

    func watchlist(completion: @escaping (String) -> Void) {
        getText(path: "/natebot/imessage/watchlist", fallback: "Could not fetch watchlist.", completion: completion)
    }

    func chat(message: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: baseURL + "/imessage/chat") else {
            completion("FinForge chat unavailable.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["message": message]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[FinForge] Chat error: \(error.localizedDescription)")
                completion("FinForge chat unavailable.")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                completion("FinForge chat returned an unexpected response.")
                return
            }
            completion(text)
        }.resume()
    }

    // MARK: - Helpers

    private func get(path: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: baseURL + path) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[FinForge] GET \(path) error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("[FinForge] GET \(path) returned \(code)")
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }

    private func getText(path: String, fallback: String, completion: @escaping (String) -> Void) {
        get(path: path) { data in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                completion("⚠️ \(fallback)")
                return
            }
            completion(text)
        }
    }
}
