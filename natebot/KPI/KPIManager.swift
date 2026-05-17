import Foundation

// MARK: - Pending Check-in State

private enum PendingCheckin: Equatable {
    case morningEnergy
    case nightlyMetrics
}

// MARK: - KPIManager
// Orchestrates all KPI check-in logic:
//   Part 1: Morning energy prompt + response
//   Part 2: Nightly metrics prompt + response
//   Part 3: Goal check-in side-effects (called from GoalAction)
//   Part 4: /kpi slash command handler
//   Part 5: 9 PM streak alerts via psql
//   Part 6: /kpi query natural-language handler

class KPIManager {
    private let client: KPIClient
    private let claude: ClaudeAPI
    private let reply: ReplyAction
    private let log: ActivityLog
    private let dbURL: String

    // State machine for awaiting check-in replies
    private var pendingCheckin: PendingCheckin?
    private let stateLock = NSLock()

    // In-memory note accumulation — avoids a psql read on every /kpi note
    private var noteLines: [String] = []
    private var notesDate: String = ""
    private let notesLock = NSLock()

    init(config: KPIConfig, claude: ClaudeAPI, reply: ReplyAction, log: ActivityLog) {
        self.client = KPIClient(apiURL: config.apiUrl, apiKey: config.apiKey)
        self.claude = claude
        self.reply  = reply
        self.log    = log
        self.dbURL  = config.dbUrl
        seedNotesFromDB()
    }

    /// On startup: load today's existing notes from DB into memory so restarts don't lose prior notes.
    private func seedNotesFromDB() {
        let today = todayString()
        let sql = "SELECT COALESCE(notes, '') FROM kpi_daily_log WHERE date = '\(today)' LIMIT 1;"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            if let raw = self.client.queryDB(sql: sql, dbURL: self.dbURL) {
                let existing = self.unquoteCSV(raw)
                let lines = existing.components(separatedBy: "\n").filter { !$0.isEmpty }
                guard !lines.isEmpty else { return }
                self.notesLock.lock()
                self.noteLines = lines
                self.notesDate = today
                self.notesLock.unlock()
                print("[KPIManager] Seeded \(lines.count) note(s) from DB for \(today)")
            }
        }
    }

    // MARK: - Part 1: Morning Energy Check-in

    /// Called by MorningBriefing after the briefing message is sent.
    func sendMorningCheckin() {
        let msg = """
        Quick check-in:
        Energy on waking (1-10): __
        Reply with just a number, e.g. "7"
        """
        reply.send(msg)
        setPending(.morningEnergy)

        // Auto-cancel after 4 hours if no reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 4 * 3600) { [weak self] in
            self?.clearPendingIfStill(.morningEnergy)
        }
    }

    // MARK: - Part 2: Nightly Check-in (10 PM)

    func scheduleNightlyCheckin() {
        scheduleDaily(hour: 22, minute: 0) { [weak self] in
            self?.sendNightlyCheckin()
        }
    }

    private func sendNightlyCheckin() {
        let msg = """
        End of day check-in:
        Meaningful convos today: __
        New people met: __
        Ideas generated: __
        Life satisfaction (1-10): __

        Reply: 2, 1, 3, 7
        """
        reply.send(msg)
        setPending(.nightlyMetrics)

        // Auto-cancel after 6 hours if no reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 6 * 3600) { [weak self] in
            self?.clearPendingIfStill(.nightlyMetrics)
        }
    }

    // MARK: - Pending Response Handler (called from MessageWatcher pipeline)

    /// Returns true if the message was consumed by a pending check-in.
    /// Slash commands are never intercepted regardless of pending state.
    func handlePendingResponse(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return false }

        stateLock.lock()
        let pending = pendingCheckin
        stateLock.unlock()
        guard let pending = pending else { return false }

        switch pending {
        case .morningEnergy:
            guard let n = parseEnergy(trimmed) else { return false } // not a valid energy reply
            clearPendingIfStill(.morningEnergy)
            client.ingest(["energy_am": n])
            let replyMsg = "Logged energy: \(n)/10"
            reply.send(replyMsg)
            log.append(from: "user", message: trimmed, action: "kpi_energy_am", result: "ok", reply: replyMsg)
            return true

        case .nightlyMetrics:
            clearPendingIfStill(.nightlyMetrics)
            parseNightly(trimmed)
            return true
        }
    }

    // MARK: - Public ingest (for NLP kpi_log dispatch in main.swift)

    func ingestFields(_ fields: [String: Any]) {
        client.ingest(fields)
    }

    // MARK: - Part 3: Goal Check-in Side-Effects

    /// Called from GoalAction after any goal check-in. Posts KPI field if the goal matches.
    func handleGoalCheckin(goalName: String) {
        let lower = goalName.lowercased()
        var fields: [String: Any] = [:]

        if lower.contains("morning prayer") {
            fields["prayer_am"] = true
        } else if lower.contains("nighttime prayer") || (lower.contains("night") && lower.contains("prayer")) {
            fields["prayer_pm"] = true
        } else if lower.contains("scripture") {
            fields["scripture"] = true
        } else if lower.contains("church") {
            fields["church"] = true
        } else if lower.contains("gym") {
            fields["workout_type"] = "Gym"
        }

        guard !fields.isEmpty else { return }
        client.ingest(fields)
        print("[KPIManager] Goal side-effect: \(fields)")
    }

    // MARK: - Part 4: /kpi Slash Command Handler

    func handleCommand(subcommand: String, args: [String], rawMessage: String,
                       completion: @escaping (String) -> Void) {
        switch subcommand.lowercased() {

        case "lc":
            guard let n = args.first.flatMap({ Int($0) }) else {
                completion("Usage: /kpi lc <number>"); return
            }
            client.ingest(["lc_solved": n]) { ok in
                completion(ok ? "Logged." : "Failed to log — check server.")
            }

        case "temple":
            client.ingest(["temple": true]) { ok in
                completion(ok ? "Logged." : "Failed to log.")
            }

        case "church":
            client.ingest(["church": true]) { ok in
                completion(ok ? "Logged." : "Failed to log.")
            }

        case "sat":
            guard let n = args.first.flatMap({ Int($0) }), (1...10).contains(n) else {
                completion("Usage: /kpi sat <1-10>"); return
            }
            client.ingest(["life_sat": n]) { ok in
                completion(ok ? "Logged." : "Failed to log.")
            }

        case "energy":
            guard let n = args.first.flatMap({ Int($0) }), (1...10).contains(n) else {
                completion("Usage: /kpi energy <1-10>"); return
            }
            client.ingest(["energy_am": n]) { ok in
                completion(ok ? "Logged." : "Failed to log.")
            }

        case "met":
            guard let n = args.first.flatMap({ Int($0) }) else {
                completion("Usage: /kpi met <number>"); return
            }
            client.ingest(["new_people": n]) { ok in
                completion(ok ? "Logged." : "Failed to log.")
            }

        case "ideas":
            guard let n = args.first.flatMap({ Int($0) }) else {
                completion("Usage: /kpi ideas <number>"); return
            }
            client.ingest(["ideas_count": n]) { ok in
                completion(ok ? "Logged." : "Failed to log.")
            }

        case "note":
            let noteText = args.joined(separator: " ")
            guard !noteText.isEmpty else {
                completion("Usage: /kpi note <text>"); return
            }
            let ts = DateFormatter().apply { $0.dateFormat = "HH:mm" }.string(from: Date())
            let newEntry = "• [\(ts)] \(noteText)"
            let today = todayString()

            // Append to in-memory list (reset if it's a new day), then POST the full list
            notesLock.lock()
            if notesDate != today {
                noteLines = []
                notesDate = today
            }
            noteLines.append(newEntry)
            let combined = noteLines.joined(separator: "\n")
            notesLock.unlock()

            client.ingest(["notes": combined]) { ok in
                completion(ok ? "Logged." : "Failed to log.")
            }

        case "status":
            fetchTodayStatus(completion: completion)
            return

        case "week":
            fetchWeekSummary(completion: completion)
            return

        case "query":
            let question = args.joined(separator: " ")
            guard !question.isEmpty else {
                completion("Usage: /kpi query <question>"); return
            }
            handleNLQuery(question: question, completion: completion)
            return

        default:
            completion("""
            /kpi commands:
              lc <n>        — LeetCode problems solved
              temple        — temple attendance
              church        — church attendance
              sat <n>       — life satisfaction (1-10)
              energy <n>    — morning energy (1-10)
              met <n>       — new people met
              ideas <n>     — ideas generated
              note <text>   — append a note
              status        — today's KPI row
              week          — last 7 days summary
              query <q>     — ask a natural language question
            """)
        }

        // Synchronous path already called completion via the ingest callback above.
    }

    // MARK: - Part 5: Streak Alerts (9 PM)

    func scheduleStreakAlerts() {
        scheduleDaily(hour: 21, minute: 0) { [weak self] in
            self?.checkStreaks()
        }
    }

    private func checkStreaks() {
        let sql = """
        SELECT date, prayer_am, life_sat, lc_solved, scripture
        FROM kpi_daily_log
        WHERE date >= CURRENT_DATE - INTERVAL '29 days'
        ORDER BY date DESC;
        """
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let output = self.client.queryDB(sql: sql, dbURL: self.dbURL) else { return }
            let alerts = self.buildStreakAlerts(csv: output)
            guard !alerts.isEmpty else { return }
            DispatchQueue.main.async {
                for alert in alerts {
                    self.reply.send(alert)
                    self.log.append(from: "system", message: "streak_check",
                                    action: "kpi_streak", result: "sent", reply: alert)
                }
            }
        }
    }

    private func buildStreakAlerts(csv: String) -> [String] {
        // CSV columns (from --csv --tuples-only): date,prayer_am,life_sat,lc_solved,scripture
        let rows = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        var prayerAmVals: [Bool?] = []
        var lifeSatVals:  [Int?]  = []
        var lcVals:       [Int?]  = []
        var scriptureVals:[Bool?] = []
        var todayHasLC = false

        for (i, row) in rows.enumerated() {
            let cols = row.components(separatedBy: ",")
            let prayerAm  = cols.count > 1 ? parseBool(cols[1]) : nil
            let lifeSat   = cols.count > 2 ? parseInt(cols[2])  : nil
            let lc        = cols.count > 3 ? parseInt(cols[3])  : nil
            let scripture = cols.count > 4 ? parseBool(cols[4]) : nil
            prayerAmVals.append(prayerAm)
            lifeSatVals.append(lifeSat)
            lcVals.append(lc)
            scriptureVals.append(scripture)
            if i == 0 { todayHasLC = lc != nil }
        }

        var alerts: [String] = []

        if consecutiveMissing(prayerAmVals, count: 3) {
            alerts.append("Morning prayer streak broken — 3 days. Want to reset tonight?")
        }

        let loggedSat = lifeSatVals.compactMap { $0 }
        if loggedSat.count >= 3 && isDeclining(Array(loggedSat.prefix(3))) {
            alerts.append("Life satisfaction has been trending down 3 days. How are you doing?")
        }

        if !todayHasLC {
            alerts.append("No LC problems logged today — streak at risk.")
        }

        if consecutiveMissing(scriptureVals, count: 3) {
            alerts.append("Scripture reading streak broken — 3 days.")
        }

        return alerts
    }

    // MARK: - Part 6: NL Query

    private func handleNLQuery(question: String, completion: @escaping (String) -> Void) {
        let sql = """
        SELECT date, energy_am, life_sat, meaningful_convos, new_people, ideas_count,
               prayer_am, prayer_pm, scripture, church, workout_type, lc_solved, notes
        FROM kpi_daily_log
        WHERE date >= CURRENT_DATE - INTERVAL '89 days'
        ORDER BY date DESC;
        """
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let dbData = self.client.queryDB(sql: sql, dbURL: self.dbURL) ?? "No data available."
            let system = """
            You are NateBot, Nathan's personal health and productivity assistant.
            Answer his question conversationally based on his KPI log data.
            CSV columns: date,energy_am,life_sat,meaningful_convos,new_people,ideas_count,prayer_am,prayer_pm,scripture,church,workout_type,lc_solved,notes
            Be concise, warm, and specific. Plain text only (no markdown).
            """
            let userMsg = "Last 90 days of KPI data:\n\(dbData)\n\nQuestion: \(question)"
            self.claude.call(system: system, userMessage: userMsg, maxTokens: 1024) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text): completion(text)
                    case .failure(let err):  completion("Could not answer: \(err.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - DB Queries for /kpi status and /kpi week

    private func fetchTodayStatus(completion: @escaping (String) -> Void) {
        let today = todayString()
        // Use row_to_json to avoid enumerating columns manually
        let sql = "SELECT row_to_json(t) FROM kpi_daily_log t WHERE date = '\(today)' LIMIT 1;"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let output = self.client.queryDB(sql: sql, dbURL: self.dbURL),
                  !output.isEmpty else {
                DispatchQueue.main.async { completion("No KPI data logged today yet.") }
                return
            }
            let formatted = self.formatJSON(output, header: "Today's KPI (\(today)):")
            DispatchQueue.main.async { completion(formatted) }
        }
    }

    private func fetchWeekSummary(completion: @escaping (String) -> Void) {
        let sql = """
        SELECT date, energy_am, life_sat, meaningful_convos, new_people, ideas_count,
               prayer_am, prayer_pm, scripture, church, workout_type, lc_solved
        FROM kpi_daily_log
        WHERE date >= CURRENT_DATE - INTERVAL '6 days'
        ORDER BY date DESC;
        """
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let output = self.client.queryDB(sql: sql, dbURL: self.dbURL),
                  !output.isEmpty else {
                DispatchQueue.main.async { completion("No KPI data for the past week.") }
                return
            }
            let formatted = self.formatWeekCSV(output)
            DispatchQueue.main.async { completion(formatted) }
        }
    }

    // MARK: - Nightly Parsing Helpers

    private func parseNightly(_ text: String) {
        let parts = text.components(separatedBy: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count == 4 {
            let fields: [String: Any] = [
                "meaningful_convos": parts[0],
                "new_people":        parts[1],
                "ideas_count":       parts[2],
                "life_sat":          parts[3]
            ]
            client.ingest(fields)
            let msg = "Logged. Convos: \(parts[0]), new people: \(parts[1]), ideas: \(parts[2]), satisfaction: \(parts[3])/10"
            reply.send(msg)
            log.append(from: "user", message: text, action: "kpi_nightly", result: "ok", reply: msg)
        } else {
            fuzzyParseNightly(text)
        }
    }

    private func fuzzyParseNightly(_ message: String) {
        let system = """
        Extract these metrics from the user's message. Return compact JSON only.
        Fields: meaningful_convos (int), new_people (int), ideas_count (int), life_sat (int 1-10).
        Omit fields you cannot determine. Return only a valid JSON object.
        """
        claude.call(system: system, userMessage: message, maxTokens: 256) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let text):
                guard let jsonStr = text.extractJSONObject(),
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      !json.isEmpty else {
                    self.reply.send("Couldn't parse that. Try: 2, 1, 3, 7 (convos, new people, ideas, satisfaction)")
                    return
                }
                self.client.ingest(json)
                var parts: [String] = []
                if let v = json["meaningful_convos"] { parts.append("convos: \(v)") }
                if let v = json["new_people"]        { parts.append("new people: \(v)") }
                if let v = json["ideas_count"]       { parts.append("ideas: \(v)") }
                if let v = json["life_sat"]          { parts.append("satisfaction: \(v)/10") }
                let msg = "Logged. " + parts.joined(separator: ", ")
                self.reply.send(msg)
                self.log.append(from: "user", message: message, action: "kpi_nightly_fuzzy", result: "ok", reply: msg)
            case .failure:
                self.reply.send("Couldn't parse that. Try: 2, 1, 3, 7 (convos, new people, ideas, satisfaction)")
            }
        }
    }

    private func parseEnergy(_ text: String) -> Int? {
        // "7" or "7/10"
        if let n = Int(text), (1...10).contains(n) { return n }
        if let range = text.range(of: #"^(\d+)\s*/\s*10$"#, options: .regularExpression) {
            let digits = String(text[range]).components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }.first
            if let n = digits, (1...10).contains(n) { return n }
        }
        return nil
    }

    // MARK: - Output Formatters

    private func formatJSON(_ jsonString: String, header: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "\(header)\n\(jsonString)"
        }
        var lines = [header]
        for key in json.keys.sorted() {
            guard let val = json[key], !(val is NSNull) else { continue }
            lines.append("  \(key): \(val)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatWeekCSV(_ csv: String) -> String {
        let headers = ["date","energy_am","life_sat","meaningful_convos","new_people",
                       "ideas_count","prayer_am","prayer_pm","scripture","church",
                       "workout_type","lc_solved"]
        var lines = ["Last 7 days:"]
        for row in csv.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
            let cols = row.components(separatedBy: ",")
            guard let date = cols.first, !date.isEmpty else { continue }
            lines.append("\n\(date):")
            for (i, h) in headers.enumerated() where i > 0 && i < cols.count {
                let v = cols[i].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { lines.append("  \(h): \(v)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Streak Helpers

    private func consecutiveMissing(_ values: [Bool?], count: Int) -> Bool {
        var streak = 0
        for v in values {
            if v == nil || v == false {
                streak += 1
                if streak >= count { return true }
            } else {
                break
            }
        }
        return false
    }

    private func isDeclining(_ values: [Int]) -> Bool {
        guard values.count >= 3 else { return false }
        // values[0] is most recent; declining means most recent < previous < one before
        return values[0] < values[1] && values[1] < values[2]
    }

    private func parseBool(_ s: String) -> Bool? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "t" || t == "true"  { return true }
        if t == "f" || t == "false" { return false }
        return nil
    }

    private func parseInt(_ s: String) -> Int? {
        Int(s.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - CSV Unquoting (for psql --csv output)

    /// Strip surrounding CSV double-quotes and unescape doubled quotes.
    private func unquoteCSV(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            let inner = String(t.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\"\"", with: "\"")
        }
        return t
    }

    // MARK: - State Helpers

    private func setPending(_ state: PendingCheckin) {
        stateLock.lock()
        pendingCheckin = state
        stateLock.unlock()
    }

    private func clearPendingIfStill(_ state: PendingCheckin) {
        stateLock.lock()
        if pendingCheckin == state { pendingCheckin = nil }
        stateLock.unlock()
    }

    // MARK: - Scheduling

    /// Schedule a one-shot daily fire at hh:mm local time, then auto-reschedule.
    private func scheduleDaily(hour: Int, minute: Int, block: @escaping () -> Void) {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = hour
        comps.minute = minute
        comps.second = 0
        guard var fire = Calendar.current.date(from: comps) else { return }
        if fire <= Date() {
            fire = Calendar.current.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        let delay = fire.timeIntervalSinceNow
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            block()
            self?.scheduleDaily(hour: hour, minute: minute, block: block)
        }
    }

    // MARK: - Date Helper

    private func todayString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }
}

// MARK: - DateFormatter builder helper

private extension DateFormatter {
    func apply(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        configure(self)
        return self
    }
}
