import Foundation

// MARK: - Log Entry

struct LogEntry: Codable {
    let timestamp: String   // ISO8601
    let from: String        // sender or "system"
    let message: String     // raw incoming text
    let action: String      // e.g. "cal_add"
    let result: String      // "success" | "error" | ...
    let reply: String       // outgoing reply text
}

// MARK: - Activity Log

class ActivityLog {
    private let logURL: URL
    private let maxEntries: Int
    private var entries: [LogEntry] = []
    private let queue = DispatchQueue(label: "com.natebot.log", attributes: .concurrent)

    init(maxEntries: Int) {
        self.maxEntries = maxEntries

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("NateBot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logURL = dir.appendingPathComponent("activity.log")

        loadEntries()
    }

    // MARK: - Public

    func append(
        from sender: String,
        message: String,
        action: String,
        result: String,
        reply: String
    ) {
        queue.async(flags: .barrier) {
            let ts = ISO8601DateFormatter().string(from: Date())
            // Never log passphrase — sanitize message
            let safeMessage = message.count > 500 ? String(message.prefix(500)) + "…" : message
            let safeReply   = reply.count > 500   ? String(reply.prefix(500)) + "…"   : reply

            let entry = LogEntry(
                timestamp: ts,
                from: sender,
                message: safeMessage,
                action: action,
                result: result,
                reply: safeReply
            )
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            self.persist()
        }
    }

    func recent(count: Int = 10) -> [LogEntry] {
        queue.sync { Array(entries.suffix(count)) }
    }

    func formattedRecent() -> String {
        let r = recent(count: 10)
        guard !r.isEmpty else { return "📋 No recent activity." }

        let lines = r.map { e -> String in
            let ts = String(e.timestamp.prefix(19)).replacingOccurrences(of: "T", with: " ")
            return "[\(ts)] \(e.action) → \(e.result)"
        }
        return "📋 Recent Activity:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func loadEntries() {
        guard let data = try? Data(contentsOf: logURL),
              let loaded = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
        entries = loaded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: logURL, options: .atomic)
    }
}
