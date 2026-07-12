import Foundation

// MARK: - LocationEntry

struct LocationEntry: Codable {
    let device: String
    let address: String
    let label: String?
    let latitude: Double?
    let longitude: Double?
    let timestamp: String   // ISO8601
}

// MARK: - LocationTracker

/// Reads device locations from the KPI postgres `location_log` table.
class LocationTracker {
    private let dbURL: String
    private let device: String
    private let namedLocations: [String: String]

    init(dbURL: String, device: String, namedLocations: [String: String]) {
        self.dbURL = dbURL
        self.device = device
        self.namedLocations = namedLocations
    }

    // MARK: - Scheduling

    /// Start polling loop: fires at :00 and :30 between 5:00 AM and midnight.
    func startTracking() {
        print("[LocationTracker] Starting — reading from KPI location_log")
        scheduleNext()
    }

    private func scheduleNext() {
        guard let nextFire = nextScrapeDate() else {
            guard let tomorrow5am = tomorrowAt(hour: 5, minute: 0) else { return }
            let delay = tomorrow5am.timeIntervalSinceNow
            print("[LocationTracker] Outside active hours. Next poll at 5:00 AM (\(Int(delay / 60)) min)")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fireAndReschedule()
            }
            return
        }
        let delay = max(nextFire.timeIntervalSinceNow, 1)
        print("[LocationTracker] Next poll in \(Int(delay / 60)) minutes")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fireAndReschedule()
        }
    }

    private func fireAndReschedule() {
        scrapeNow { [weak self] _ in
            self?.scheduleNext()
        }
    }

    private func nextScrapeDate() -> Date? {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.hour, .minute], from: now)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        guard hour >= 5 && hour <= 23 else { return nil }
        var nextMinute: Int
        var nextHour = hour
        if minute < 30 { nextMinute = 30 } else { nextMinute = 0; nextHour = hour + 1 }
        if nextHour > 23 { return nil }
        var fireComps = cal.dateComponents([.year, .month, .day], from: now)
        fireComps.hour = nextHour
        fireComps.minute = nextMinute
        fireComps.second = 0
        return cal.date(from: fireComps)
    }

    private func tomorrowAt(hour: Int, minute: Int) -> Date? {
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) else { return nil }
        var comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        return cal.date(from: comps)
    }

    // MARK: - Queries

    /// Fetch the latest location entry from the DB.
    func scrapeNow(completion: @escaping (LocationEntry?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(nil); return }
            let sql = "SELECT to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), lat, lon, resolved_location, street, city, state FROM location_log ORDER BY ts DESC LIMIT 1"
            guard let csv = self.queryDB(sql: sql),
                  let entry = self.parseRow(csv.components(separatedBy: "\n").first ?? "") else {
                print("[LocationTracker] No location data in DB")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            print("[LocationTracker] Latest: \(entry.label ?? entry.address)")
            DispatchQueue.main.async { completion(entry) }
        }
    }

    /// Latest entry for the configured device.
    func latestEntry() -> LocationEntry? {
        let sql = "SELECT to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), lat, lon, resolved_location, street, city, state FROM location_log ORDER BY ts DESC LIMIT 1"
        guard let csv = queryDB(sql: sql) else { return nil }
        return parseRow(csv.components(separatedBy: "\n").first ?? "")
    }

    /// All entries logged today (local calendar day).
    func todayHistory() -> [LocationEntry] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let startStr = fmt.string(from: todayStart)
        let endStr = fmt.string(from: todayEnd)
        let sql = "SELECT to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), lat, lon, resolved_location, street, city, state FROM location_log WHERE ts >= '\(startStr)' AND ts < '\(endStr)' ORDER BY ts ASC"
        guard let csv = queryDB(sql: sql) else { return [] }
        return csv.components(separatedBy: "\n").compactMap { parseRow($0) }
    }

    /// All entries for a specific date string (YYYY-MM-DD) in local time.
    func entries(for dateStr: String) -> [LocationEntry] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let dayStart = df.date(from: dateStr) else { return [] }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let startStr = fmt.string(from: dayStart)
        let endStr = fmt.string(from: dayEnd)
        let sql = "SELECT to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), lat, lon, resolved_location, street, city, state FROM location_log WHERE ts >= '\(startStr)' AND ts < '\(endStr)' ORDER BY ts ASC"
        guard let csv = queryDB(sql: sql) else { return [] }
        return csv.components(separatedBy: "\n").compactMap { parseRow($0) }
    }

    // MARK: - Label Resolution

    private func resolveLabel(for address: String) -> String? {
        let lower = address.lowercased()
        for (substring, label) in namedLocations {
            if lower.contains(substring.lowercased()) { return label }
        }
        return nil
    }

    // MARK: - Summary

    /// Generate a human-readable summary of today's locations (for briefing).
    func generateSummary() -> String {
        let history = todayHistory()
        guard !history.isEmpty else { return "  No location data today." }

        var ranges: [(label: String, start: String, end: String)] = []
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"

        for entry in history {
            let displayName = entry.label ?? entry.address
            let entryDate = ISO8601DateFormatter().date(from: entry.timestamp) ?? Date()
            let timeStr = tf.string(from: entryDate)
            if let last = ranges.last, last.label == displayName {
                ranges[ranges.count - 1].end = timeStr
            } else {
                ranges.append((label: displayName, start: timeStr, end: timeStr))
            }
        }

        if var last = ranges.last {
            let latestTs = history.last.flatMap { ISO8601DateFormatter().date(from: $0.timestamp) }
            if let ts = latestTs, Date().timeIntervalSince(ts) < 3600 {
                last.end = "Now"
                ranges[ranges.count - 1] = last
            }
        }

        return ranges.map { r in
            if r.start == r.end { return "  \u{2022} \(r.label) \u{2014} \(r.start)" }
            return "  \u{2022} \(r.label) \u{2014} \(r.start) \u{2013} \(r.end)"
        }.joined(separator: "\n")
    }

    // MARK: - CSV Row Parser

    private func parseRow(_ line: String) -> LocationEntry? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // CSV columns: ts, lat, lon, resolved_location, street, city, state
        let cols = parseCSVLine(line)
        guard cols.count >= 3 else { return nil }
        let ts = cols[0]
        guard let lat = Double(cols[1]), let lon = Double(cols[2]) else { return nil }
        let resolved = cols.count > 3 ? cols[3] : ""
        let street   = cols.count > 4 ? cols[4] : ""
        let city     = cols.count > 5 ? cols[5] : ""
        let state    = cols.count > 6 ? cols[6] : ""
        let address  = buildAddress(street: street, city: city, state: state, resolved: resolved)
        guard !address.isEmpty else { return nil }
        let label = resolveLabel(for: address)
        return LocationEntry(device: device, address: address, label: label, latitude: lat, longitude: lon, timestamp: ts)
    }

    private func buildAddress(street: String, city: String, state: String, resolved: String) -> String {
        let parts = [street, city, state].filter { !$0.isEmpty }
        return parts.isEmpty ? resolved : parts.joined(separator: ", ")
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" { inQuotes.toggle() }
            else if char == "," && !inQuotes { fields.append(current); current = "" }
            else { current.append(char) }
        }
        fields.append(current)
        return fields
    }

    // MARK: - psql Runner

    private func queryDB(sql: String) -> String? {
        let args = [dbURL, "--no-align", "--tuples-only", "--csv", "-c", sql]
        let candidates = [
            "/opt/homebrew/opt/postgresql@17/bin/psql",
            "/opt/homebrew/bin/psql",
            "/usr/local/bin/psql",
            "/usr/bin/psql",
        ]
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let process = Process()
            process.launchPath = path
            process.arguments = args
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do { try process.run(); process.waitUntilExit() } catch { continue }
            if process.terminationStatus == 0 {
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[LocationTracker] psql error: \(err.prefix(200))")
        }
        print("[LocationTracker] psql not found.")
        return nil
    }
}
