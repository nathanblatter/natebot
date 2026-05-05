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

/// Scrapes Find My on a schedule, geocodes addresses, and persists location history.
class LocationTracker {
    private let scraper: FindMyLocationScraper
    private let device: String
    private let namedLocations: [String: String]
    private let queue = DispatchQueue(label: "com.natebot.location", attributes: .concurrent)

    /// Set from main.swift to enable location-based goal auto-check-in.
    var goalStore: GoalStore?
    var reply: ReplyAction?

    private var entries: [LocationEntry] = []
    private var geocodeCache: [String: [String: Double]] = [:]  // address → {"lat": x, "lon": y}

    private let historyURL: URL
    private let cacheURL: URL

    private let retentionDays = 7

    init(scraper: FindMyLocationScraper, device: String, namedLocations: [String: String]) {
        self.scraper = scraper
        self.device = device
        self.namedLocations = namedLocations

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("NateBot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.historyURL = dir.appendingPathComponent("location_history.json")
        self.cacheURL = dir.appendingPathComponent("geocode_cache.json")

        loadEntries()
        loadGeocodeCache()
    }

    // MARK: - Scheduling

    /// Start the scrape loop: fires at :00 and :30 between 5:00 AM and midnight.
    func startTracking() {
        print("[LocationTracker] Starting location tracking for device: \(device)")
        scheduleNext()
    }

    private func scheduleNext() {
        guard let nextFire = nextScrapeDate() else {
            // Outside active hours — schedule for 5:00 AM tomorrow
            guard let tomorrow5am = tomorrowAt(hour: 5, minute: 0) else { return }
            let delay = tomorrow5am.timeIntervalSinceNow
            print("[LocationTracker] Outside active hours. Next scrape at 5:00 AM (\(Int(delay / 60)) min)")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fireAndReschedule()
            }
            return
        }

        let delay = max(nextFire.timeIntervalSinceNow, 1)
        print("[LocationTracker] Next scrape in \(Int(delay / 60)) minutes")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fireAndReschedule()
        }
    }

    private func fireAndReschedule() {
        scrapeNow { [weak self] _ in
            self?.scheduleNext()
        }
    }

    /// Returns the next :00 or :30 timestamp between 5:00 AM and midnight.
    private func nextScrapeDate() -> Date? {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }

        // Active hours: 5:00 AM (5) through 11:59 PM (23)
        guard hour >= 5 && hour <= 23 else { return nil }

        // Find next :00 or :30
        var nextMinute: Int
        var nextHour = hour

        if minute < 30 {
            nextMinute = 30
        } else {
            nextMinute = 0
            nextHour = hour + 1
        }

        // Past midnight?
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
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return cal.date(from: comps)
    }

    // MARK: - Scraping

    /// Perform an immediate scrape, geocode, and persist.
    func scrapeNow(completion: @escaping (LocationEntry?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(nil); return }

            let devices = self.scraper.scrapeDeviceLocations()
            guard let found = devices.first(where: {
                $0.name.lowercased().contains(self.device.lowercased())
            }) else {
                print("[LocationTracker] Device '\(self.device)' not found in scrape. Found: \(devices.map { $0.name })")
                completion(nil)
                return
            }

            guard found.address != "No location found" else {
                print("[LocationTracker] \(self.device): No location found")
                completion(nil)
                return
            }

            let label = self.resolveLabel(for: found.address)
            let ts = ISO8601DateFormatter().string(from: Date())

            print("[LocationTracker] Scrape: \(self.device) at \(label ?? found.address)")

            // Geocode (check cache first)
            self.geocode(address: found.address) { lat, lon in
                let entry = LocationEntry(
                    device: self.device,
                    address: found.address,
                    label: label,
                    latitude: lat,
                    longitude: lon,
                    timestamp: ts
                )

                self.queue.async(flags: .barrier) {
                    self.entries.append(entry)
                    self.pruneOldEntries()
                    self.persistEntries()
                }

                // Check for goal auto-check-in
                self.checkGoalAutoComplete(for: entry)

                DispatchQueue.main.async { completion(entry) }
            }
        }
    }

    // MARK: - Goal Auto-Check-In

    /// After each scrape, check if the location matches any goal's location field.
    private func checkGoalAutoComplete(for entry: LocationEntry) {
        guard let store = goalStore, let label = entry.label else { return }

        let goals = store.listGoals()
        for goal in goals {
            guard let goalLocation = goal.location,
                  goalLocation.lowercased() == label.lowercased() else { continue }

            // Check if already completed for the relevant period
            let alreadyDone: Bool
            if goal.frequency == "weekly" {
                alreadyDone = store.isCompletedThisWeek(goalId: goal.id)
            } else {
                alreadyDone = store.isCompletedToday(goalId: goal.id)
            }

            guard !alreadyDone else { continue }

            // Auto-check-in
            store.log(goalId: goal.id, source: "location", note: "Auto: detected at \(label)")
            let msg = "📍✅ Auto-checked in: \(goal.name) (you're at \(label))"
            print("[LocationTracker] \(msg)")
            reply?.send(msg)
        }
    }

    // MARK: - Label Resolution

    private func resolveLabel(for address: String) -> String? {
        let lower = address.lowercased()
        for (substring, label) in namedLocations {
            if lower.contains(substring.lowercased()) {
                return label
            }
        }
        return nil
    }

    // MARK: - Geocoding (Nominatim)

    private func geocode(address: String, completion: @escaping (Double?, Double?) -> Void) {
        // Check cache
        if let cached = queue.sync(execute: { geocodeCache[address] }) {
            completion(cached["lat"], cached["lon"])
            return
        }

        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://nominatim.openstreetmap.org/search?q=\(encoded)&format=json&limit=1") else {
            completion(nil, nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("NateBot/1.0", forHTTPHeaderField: "User-Agent")  // Nominatim requires User-Agent
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = results.first,
                  let latStr = first["lat"] as? String, let lat = Double(latStr),
                  let lonStr = first["lon"] as? String, let lon = Double(lonStr) else {
                if let error = error {
                    print("[LocationTracker] Geocode error for '\(address)': \(error.localizedDescription)")
                }
                completion(nil, nil)
                return
            }

            // Cache the result
            self?.queue.async(flags: .barrier) {
                self?.geocodeCache[address] = ["lat": lat, "lon": lon]
                self?.persistGeocodeCache()
            }

            completion(lat, lon)
        }.resume()
    }

    // MARK: - Query API

    /// All entries for today for the configured device (local time).
    func todayHistory() -> [LocationEntry] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
        let fmt = ISO8601DateFormatter()
        return queue.sync {
            entries.filter { e in
                e.device == device &&
                (fmt.date(from: e.timestamp).map { $0 >= todayStart && $0 < todayEnd } ?? false)
            }
        }
    }

    /// All entries for a specific date string (YYYY-MM-DD) in local time.
    func entries(for dateStr: String) -> [LocationEntry] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let dayStart = df.date(from: dateStr) else { return [] }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let fmt = ISO8601DateFormatter()
        return queue.sync {
            entries.filter { e in
                e.device == device &&
                (fmt.date(from: e.timestamp).map { $0 >= dayStart && $0 < dayEnd } ?? false)
            }
        }
    }

    /// Latest entry for the configured device.
    func latestEntry() -> LocationEntry? {
        queue.sync {
            entries.filter { $0.device == device }.last
        }
    }

    /// Generate a human-readable summary of today's locations (for briefing).
    func generateSummary() -> String {
        let history = todayHistory()
        guard !history.isEmpty else { return "  No location data today." }

        // Collapse consecutive same-location entries into ranges
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

        // Format: mark the last one as "Now" if it's from the last hour
        if var last = ranges.last {
            let latestTs = history.last.flatMap { ISO8601DateFormatter().date(from: $0.timestamp) }
            if let ts = latestTs, Date().timeIntervalSince(ts) < 3600 {
                last.end = "Now"
                ranges[ranges.count - 1] = last
            }
        }

        return ranges.map { r in
            if r.start == r.end || r.end == "Now" && r.start == r.end {
                return "  \u{2022} \(r.label) \u{2014} \(r.start)"
            }
            return "  \u{2022} \(r.label) \u{2014} \(r.start) \u{2013} \(r.end)"
        }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func loadEntries() {
        guard let data = try? Data(contentsOf: historyURL),
              let loaded = try? JSONDecoder().decode([LocationEntry].self, from: data) else { return }
        entries = loaded
        print("[LocationTracker] Loaded \(entries.count) location entries.")
    }

    private func persistEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private func pruneOldEntries() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let cutoffStr = ISO8601DateFormatter().string(from: cutoff)
        entries = entries.filter { $0.timestamp >= cutoffStr }
    }

    private func loadGeocodeCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let loaded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return }
        geocodeCache = loaded
    }

    private func persistGeocodeCache() {
        guard let data = try? JSONEncoder().encode(geocodeCache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
