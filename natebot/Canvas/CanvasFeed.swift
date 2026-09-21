import Foundation

// MARK: - CanvasAssignment

struct CanvasAssignment {
    let uid: String
    let title: String        // SUMMARY with the trailing "[COURSE]" tag stripped
    let course: String?      // e.g. "REL C 225-037", parsed from the SUMMARY suffix
    let due: Date            // Resolved due instant (all-day → 23:59:59 in the authoritative tz)
    let allDay: Bool
    let url: String?
    let description: String?

    func toJSON(tz: TimeZone) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = tz
        var d: [String: Any] = [
            "id": uid,
            "title": title,
            "due": iso.string(from: due),
            "allDay": allDay
        ]
        if let c = course { d["course"] = c }
        if let u = url { d["url"] = u }
        if let desc = description, !desc.isEmpty { d["description"] = desc }
        return d
    }
}

// MARK: - CanvasFeed
// Fetches a Canvas (Instructure) user calendar .ics feed, parses the VEVENTs
// into assignments, and keeps an in-memory cache refreshed on an interval.
// The feed URL embeds a per-user token, so it lives in natebot.json, not the repo.

final class CanvasFeed {
    private let url: URL
    private let refreshInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.natebot.canvas", attributes: .concurrent)
    private var _assignments: [CanvasAssignment] = []
    private var _lastRefresh: Date?
    private var _lastError: String?
    var timezoneManager: TimezoneManager?

    init?(config: CanvasConfig) {
        guard config.enabled, let u = URL(string: config.icsUrl), !config.icsUrl.isEmpty else { return nil }
        self.url = u
        self.refreshInterval = TimeInterval(max(config.refreshMinutes ?? 30, 5) * 60)
    }

    private var tz: TimeZone { timezoneManager?.currentTimezone ?? TimeZone.current }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    var assignments: [CanvasAssignment] { queue.sync { _assignments } }
    var lastRefresh: Date? { queue.sync { _lastRefresh } }
    var lastError: String? { queue.sync { _lastError } }

    // MARK: - Lifecycle

    func start() {
        refresh { _ in }
        scheduleNext()
    }

    private func scheduleNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshInterval) { [weak self] in
            guard let self = self else { return }
            self.refresh { _ in }
            self.scheduleNext()
        }
    }

    /// Fetch + parse the feed. Completion receives nil on success, an error string otherwise.
    func refresh(completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let err = err {
                self.record(error: "fetch failed: \(err.localizedDescription)")
                completion(err.localizedDescription); return
            }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = "HTTP \(http.statusCode)"
                self.record(error: msg); completion(msg); return
            }
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                self.record(error: "empty or non-UTF8 body"); completion("bad body"); return
            }
            let parsed = ICSParser.parse(text, tz: self.tz)
            if parsed.isEmpty && !text.contains("BEGIN:VCALENDAR") {
                self.record(error: "response is not an iCalendar document")
                completion("not ics"); return
            }
            self.queue.async(flags: .barrier) {
                self._assignments = parsed.sorted { $0.due < $1.due }
                self._lastRefresh = Date()
                self._lastError = nil
            }
            print("[Canvas] Refreshed — \(parsed.count) assignments")
            completion(nil)
        }.resume()
    }

    private func record(error: String) {
        print("[Canvas] \(error)")
        queue.async(flags: .barrier) { self._lastError = error }
    }

    // MARK: - Queries

    /// Assignments due from now through `days` days ahead (inclusive of today).
    func upcoming(days: Int) -> [CanvasAssignment] {
        let now = Date()
        guard let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return [] }
        return assignments.filter { $0.due >= now && $0.due < end }
    }

    /// Assignments whose due instant falls within the local calendar day of `date`.
    func due(on date: Date) -> [CanvasAssignment] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return assignments.filter { $0.due >= start && $0.due < end }
    }

    /// Assignments due after the end of `date`'s day, up to `days` days later.
    func upcoming(after date: Date, days: Int) -> [CanvasAssignment] {
        let start = calendar.startOfDay(for: date)
        guard let from = calendar.date(byAdding: .day, value: 1, to: start),
              let end  = calendar.date(byAdding: .day, value: days, to: from) else { return [] }
        return assignments.filter { $0.due >= from && $0.due < end }
    }

    func statusJSON() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = ["count": assignments.count, "refreshMinutes": Int(refreshInterval / 60)]
        if let lr = lastRefresh { d["lastRefresh"] = iso.string(from: lr) }
        if let e = lastError { d["lastError"] = e }
        return d
    }
}

// MARK: - ICSParser
// Minimal RFC 5545 reader: unfolds continuation lines, walks VEVENT blocks,
// handles DATE vs DATE-TIME (UTC "Z" or floating), and unescapes TEXT values.

enum ICSParser {
    static func parse(_ raw: String, tz: TimeZone) -> [CanvasAssignment] {
        let lines = unfold(raw)
        var events: [CanvasAssignment] = []
        var current: [String: (params: [String: String], value: String)]? = nil

        for line in lines {
            if line == "BEGIN:VEVENT" { current = [:]; continue }
            if line == "END:VEVENT" {
                if let props = current, let ev = build(props, tz: tz) { events.append(ev) }
                current = nil
                continue
            }
            guard current != nil else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            // Property name + params are before the first ':' that is not inside quotes.
            // Canvas never quotes params, so a plain split is sufficient here.
            let head = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
            let headParts = head.split(separator: ";", omittingEmptySubsequences: true).map(String.init)
            guard let name = headParts.first?.uppercased() else { continue }
            var params: [String: String] = [:]
            for p in headParts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
            }
            current?[name] = (params, value)
        }
        return events
    }

    /// Join folded lines: a line starting with a space or tab continues the previous one.
    private static func unfold(_ raw: String) -> [String] {
        var out: [String] = []
        for rawLine in raw.components(separatedBy: "\n") {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += String(line.dropFirst())
            } else {
                out.append(line)
            }
        }
        return out
    }

    private static func build(_ p: [String: (params: [String: String], value: String)], tz: TimeZone) -> CanvasAssignment? {
        guard let uid = p["UID"]?.value, !uid.isEmpty,
              let summaryRaw = p["SUMMARY"]?.value,
              let dt = p["DTSTART"] else { return nil }

        let allDay = dt.params["VALUE"] == "DATE" || (dt.value.count == 8 && Int(dt.value) != nil)
        guard let due = parseDate(dt.value, allDay: allDay, tzid: dt.params["TZID"], tz: tz) else { return nil }

        let (title, course) = splitCourse(unescape(summaryRaw))
        let desc = p["DESCRIPTION"].map { unescape($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }

        return CanvasAssignment(
            uid: uid,
            title: title,
            course: course,
            due: due,
            allDay: allDay,
            url: p["URL"]?.value,
            description: (desc?.isEmpty ?? true) ? nil : desc
        )
    }

    /// "20260905" (all-day) → 23:59:59 local; "20260902T190000Z" → UTC instant;
    /// "20260902T190000" (floating / TZID) → interpreted in that zone.
    static func parseDate(_ s: String, allDay: Bool, tzid: String?, tz: TimeZone) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        if allDay {
            df.timeZone = tz
            df.dateFormat = "yyyyMMdd"
            guard let day = df.date(from: String(s.prefix(8))) else { return nil }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            return cal.date(bySettingHour: 23, minute: 59, second: 59, of: day)
        }
        if s.hasSuffix("Z") {
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return df.date(from: s)
        }
        df.timeZone = tzid.flatMap { TimeZone(identifier: $0) } ?? tz
        df.dateFormat = "yyyyMMdd'T'HHmmss"
        return df.date(from: s)
    }

    /// RFC 5545 TEXT unescaping: \n → newline, \, → , \; → ; \\ → \
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = it.next() else { out.append(c); break }
            switch n {
            case "n", "N": out.append("\n")
            case ",": out.append(",")
            case ";": out.append(";")
            case "\\": out.append("\\")
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }

    /// "Quiz 3 [REL C 225-037]" → ("Quiz 3", "REL C 225-037")
    static func splitCourse(_ summary: String) -> (String, String?) {
        let trimmed = summary.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("]"), let open = trimmed.lastIndex(of: "[") else { return (trimmed, nil) }
        let course = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        let title = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? trimmed : title, course.isEmpty ? nil : course)
    }
}
