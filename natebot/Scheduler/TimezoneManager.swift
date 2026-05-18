import Foundation

// MARK: - TimezoneManager
// Single authoritative timezone source for the entire daemon.
// All schedulers and date formatters should derive their timezone from here.

class TimezoneManager {
    private let claude: ClaudeAPI
    private let stateURL: URL
    private(set) var currentTimezone: TimeZone

    init(claude: ClaudeAPI) {
        self.claude = claude

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("NateBot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateURL = dir.appendingPathComponent("timezone.json")

        // Load persisted timezone, fall back to system
        var tz = TimeZone.current
        if let data = try? Data(contentsOf: stateURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let identifier = json["timezone"],
           let loaded = TimeZone(identifier: identifier) {
            tz = loaded
        }
        self.currentTimezone = tz
        print("[TimezoneManager] Active timezone: \(tz.identifier)")
    }

    // MARK: - Public helpers for all scheduling and formatting code

    /// Calendar using the authoritative timezone — use for all fire-date arithmetic.
    var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = currentTimezone
        return cal
    }

    /// DateFormatter pre-configured with the authoritative timezone.
    func formatter(format: String) -> DateFormatter {
        let df = DateFormatter()
        df.dateFormat = format
        df.timeZone = currentTimezone
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }

    /// Human-readable description of the current timezone + local time.
    var displayName: String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a zzz"
        df.timeZone = currentTimezone
        return "\(currentTimezone.identifier) — \(df.string(from: Date()))"
    }

    // MARK: - Resolve place name → IANA identifier via Claude

    /// Resolve an informal place/timezone name ("hawaii", "utah", "portugal") to a
    /// TimeZone and set it as the new authoritative timezone.
    func resolve(placeName: String, completion: @escaping (Result<TimeZone, Error>) -> Void) {
        let system = """
        Convert a place name, city, state, country, or casual timezone reference to a valid \
        IANA timezone identifier. Return ONLY the identifier string — no quotes, no explanation.
        Examples:
          utah           → America/Denver
          hawaii / maui  → Pacific/Honolulu
          portugal       → Europe/Lisbon
          new york       → America/New_York
          mountain time  → America/Denver
          pacific        → America/Los_Angeles
          eastern        → America/New_York
          london         → Europe/London
          tokyo          → Asia/Tokyo
          provo          → America/Denver
          utc            → UTC
        """
        claude.call(system: system, userMessage: placeName, maxTokens: 64) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let raw):
                let identifier = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines).first?
                    .trimmingCharacters(in: .whitespaces) ?? raw
                if let tz = TimeZone(identifier: identifier) {
                    self.currentTimezone = tz
                    self.persist()
                    print("[TimezoneManager] Changed to \(tz.identifier)")
                    completion(.success(tz))
                } else {
                    let msg = "'\(identifier)' is not a recognized IANA timezone identifier"
                    completion(.failure(NSError(domain: "TimezoneManager", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: msg])))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: - Convenience: fire date at a specific HH:MM in the current timezone

    /// Returns the next Date when the clock reads hh:mm in the current timezone.
    /// If that time has already passed today, returns tomorrow's occurrence.
    func nextDailyFireDate(hour: Int, minute: Int) -> Date {
        let cal = calendar
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = hour
        comps.minute = minute
        comps.second = 0
        var fire = cal.date(from: comps) ?? Date()
        if fire <= Date() {
            fire = cal.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        return fire
    }

    /// Returns the next Date when the clock reads a "HH:MM" string in the current timezone.
    func nextDailyFireDate(timeString: String) -> Date? {
        let parts = timeString.components(separatedBy: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return nextDailyFireDate(hour: h, minute: m)
    }

    // MARK: - Persistence

    private func persist() {
        let data = try? JSONSerialization.data(
            withJSONObject: ["timezone": currentTimezone.identifier]
        )
        try? data?.write(to: stateURL, options: .atomic)
    }
}
