import Foundation

// MARK: - StatusAction

class StatusAction {
    let apps: [AppConfig]

    // Track when each app was last seen healthy (for alert messages)
    var lastHealthy: [String: Date] = [:]

    init(apps: [AppConfig]) {
        self.apps = apps
        let now = Date()
        for app in apps { lastHealthy[app.name] = now }
    }

    // MARK: - All Apps

    func allApps(completion: @escaping (String) -> Void) {
        let group = DispatchGroup()
        var results: [(AppConfig, Bool, String?)] = []
        let lock = NSLock()

        for app in apps {
            group.enter()
            checkHealth(app: app) { isUp, detail in
                lock.lock()
                results.append((app, isUp, detail))
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let sorted = results.sorted { $0.0.displayName < $1.0.displayName }
            let lines = sorted.map { app, isUp, detail -> String in
                let emoji  = isUp ? "🟢" : "🔴"
                let status = isUp ? "ok" : "DOWN"
                var line   = "\(emoji) \(app.displayName) — \(status)"
                if let d = detail { line += " (\(d))" }
                return line
            }
            completion(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Single App

    func singleApp(name: String, completion: @escaping (String) -> Void) {
        guard let app = apps.first(where: {
            $0.name.lowercased() == name || $0.displayName.lowercased().contains(name)
        }) else {
            let available = apps.map { $0.name }.joined(separator: ", ")
            completion("⚠️ Unknown app '\(name)'. Available: \(available)")
            return
        }

        checkHealth(app: app) { [weak self] isUp, detail in
            guard let self = self else { return }
            let emoji  = isUp ? "🟢" : "🔴"
            let status = isUp ? "ok" : "DOWN"
            var lines: [String] = []
            var header = "\(emoji) \(app.displayName) — \(status)"
            if let d = detail { header += " (\(d))" }
            lines.append(header)

            // Fetch stats if up and stats_url provided
            if isUp, let statsURL = app.statsURL {
                self.fetchStats(urlString: statsURL) { statsText in
                    if let t = statsText { lines.append(t) }
                    completion(lines.joined(separator: "\n"))
                }
            } else {
                completion(lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Health check (used by monitors too)

    func checkHealth(app: AppConfig, completion: @escaping (_ isUp: Bool, _ detail: String?) -> Void) {
        guard let url = URL(string: app.healthURL) else {
            completion(false, "invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            let isUp = (response as? HTTPURLResponse)?.statusCode == 200

            if isUp { self.lastHealthy[app.name] = Date() }

            var detail: String? = nil

            if isUp, let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let uptime = json["uptime"] as? String {
                    detail = "uptime \(uptime)"
                } else if let uptime = json["uptime"] as? Int {
                    detail = "uptime \(Self.formatUptime(uptime))"
                } else if let uptime = json["uptime"] as? Double {
                    detail = "uptime \(Self.formatUptime(Int(uptime)))"
                }
            }

            if !isUp, let lastSeen = self.lastHealthy[app.name] {
                let elapsed = Int(-lastSeen.timeIntervalSinceNow / 60)
                detail = "last healthy: \(elapsed) min ago"
            }

            completion(isUp, detail)
        }.resume()
    }

    // MARK: - Stats

    private func fetchStats(urlString: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            let skip = ["status", "ok", "healthy"]
            let lines = json
                .filter { !skip.contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { "  \($0.key): \($0.value)" }
            completion(lines.isEmpty ? nil : lines.joined(separator: "\n"))
        }.resume()
    }

    // MARK: - Helpers

    static func formatUptime(_ seconds: Int) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
