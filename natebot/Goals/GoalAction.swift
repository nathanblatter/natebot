import Foundation

// MARK: - GoalAction

class GoalAction {
    let store: GoalStore
    private let claude: ClaudeAPI
    private let reply: ReplyAction
    let reminder: GoalReminder

    /// Set from main.swift — authoritative timezone for date display.
    var timezoneManager: TimezoneManager?

    init(store: GoalStore, claude: ClaudeAPI, reply: ReplyAction, reminder: GoalReminder) {
        self.store    = store
        self.claude   = claude
        self.reply    = reply
        self.reminder = reminder
    }

    // MARK: - Add

    func handleAdd(rawText: String, completion: @escaping (String) -> Void) {
        let system = """
        Extract a goal definition from the user's message. Return compact JSON only.
        Format: {"name":"Goal Name","frequency":"daily","reminder_time":"HH:MM","location":"LocationLabel"}
        - frequency must be "daily" or "weekly"
        - reminder_time is optional; include only if the user specifies a time. Use 24h HH:MM format.
        - location is optional; include only if the user specifies a location for auto-check-in (e.g. "Gym", "Church"). This should be a short label, not a full address.
        - name should be title-cased and concise (2-5 words)
        """
        claude.call(system: system, userMessage: rawText) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                completion("⚠️ Could not parse goal: \(err.localizedDescription)")
            case .success(let text):
                guard let jsonStr = text.extractJSONObject(),
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String,
                      let freq = json["frequency"] as? String else {
                    completion("⚠️ Could not parse goal details. Try: /goals add morning prayer daily at 8am")
                    return
                }
                let reminderTime = json["reminder_time"] as? String
                let location = json["location"] as? String
                let goal = self.store.addGoal(name: name, frequency: freq, reminderTime: reminderTime, location: location)
                self.reminder.reschedule()

                var msg = "✅ Goal added: \"\(goal.name)\" (\(goal.frequency))"
                if let t = goal.reminderTime { msg += " — reminder at \(t)" }
                if let loc = goal.location { msg += " — 📍 auto-check-in at \(loc)" }
                completion(msg)
            }
        }
    }

    // MARK: - Remove

    func handleRemove(rawText: String, completion: @escaping (String) -> Void) {
        let goals = store.listGoals()
        guard !goals.isEmpty else {
            completion("You have no goals set up yet.")
            return
        }
        let goalList = goals.map { "id:\($0.id) name:\($0.name)" }.joined(separator: "\n")
        let system = """
        Given the user's message and a list of goals, identify which goal to remove.
        Return compact JSON: {"id":"goal-uuid"}
        If no match, return {"id":""}
        Goals:\n\(goalList)
        """
        claude.call(system: system, userMessage: rawText) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                completion("⚠️ Error: \(err.localizedDescription)")
            case .success(let text):
                guard let jsonStr = text.extractJSONObject(),
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String, !id.isEmpty else {
                    completion("❌ Could not match a goal to remove. Use /goals to see your goals.")
                    return
                }
                let goalName = goals.first { $0.id == id }?.name ?? id
                if self.store.removeGoal(id: id) {
                    self.reminder.reschedule()
                    completion("✅ Removed goal: \"\(goalName)\"")
                } else {
                    completion("❌ Goal not found.")
                }
            }
        }
    }

    // MARK: - Check-in

    func handleCheckin(rawMessage: String, goalName: String, note: String?, completion: @escaping (String) -> Void) {
        let goals = store.listGoals()
        guard !goals.isEmpty else {
            completion("You have no goals set up yet. Add one with /goals add [description]")
            return
        }

        // Fuzzy match goalName against stored goals
        let matched = fuzzyMatch(input: goalName, goals: goals)
        guard let goal = matched else {
            let names = goals.map { "• \($0.name)" }.joined(separator: "\n")
            completion("❌ Couldn't match \"\(goalName)\" to a goal. Your goals:\n\(names)")
            return
        }

        store.log(goalId: goal.id, source: "nlp", note: note)
        var msg = "✅ Logged: \(goal.name)"
        if let n = note, !n.isEmpty { msg += " (\(n))" }
        completion(msg)
    }

    func handleSlashCheckin(rawText: String, completion: @escaping (String) -> Void) {
        let goals = store.listGoals()
        guard !goals.isEmpty else {
            completion("You have no goals set up yet. Add one with /goals add [description]")
            return
        }
        let matched = fuzzyMatch(input: rawText, goals: goals)
        guard let goal = matched else {
            let names = goals.map { "• \($0.name)" }.joined(separator: "\n")
            completion("❌ Couldn't match \"\(rawText)\" to a goal. Your goals:\n\(names)")
            return
        }
        store.log(goalId: goal.id, source: "slash", note: nil)
        completion("✅ Logged: \(goal.name)")
    }

    // MARK: - Status

    func handleStatus(completion: @escaping (String) -> Void) {
        let goals = store.listGoals()
        guard !goals.isEmpty else {
            completion("📋 No goals yet. Add one with /goals add [description]")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        var lines = ["🎯 Goals — \(df.string(from: Date()))"]
        let cal = timezoneManager?.calendar ?? Calendar.current
        for g in goals {
            let done: Bool
            if g.frequency == "weekly" {
                done = store.isCompletedThisWeek(goalId: g.id, calendar: cal)
            } else {
                done = store.isCompletedToday(goalId: g.id, calendar: cal)
            }
            let check = done ? "✅" : "❌"
            var line = "\(check) \(g.name) (\(g.frequency))"
            if let t = g.reminderTime { line += " — \(t)" }
            if let loc = g.location { line += " — 📍 \(loc)" }
            lines.append(line)
        }
        completion(lines.joined(separator: "\n"))
    }

    // MARK: - History

    func handleHistory(completion: @escaping (String) -> Void) {
        let goals = store.listGoals()
        guard !goals.isEmpty else {
            completion("📋 No goals yet.")
            return
        }

        let cal = timezoneManager?.calendar ?? Calendar.current
        let today = cal.startOfDay(for: Date())
        var days: [Date] = []
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: -i, to: today) {
                days.append(d)
            }
        }
        days = days.reversed()

        let df = DateFormatter()
        df.dateFormat = "EEE M/d"

        let header = "Goal" + "\t" + days.map { df.string(from: $0) }.joined(separator: "\t")
        var lines = ["📊 This Week:\n" + header]

        let weekCheckIns = store.checkInsForWeek(ending: Date())

        for g in goals {
            var cells: [String] = []
            for day in days {
                let dayStart = cal.startOfDay(for: day)
                let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                let done = weekCheckIns.contains { c in
                    c.goalId == g.id &&
                    (ISO8601DateFormatter().date(from: c.timestamp).map { $0 >= dayStart && $0 < dayEnd } ?? false)
                }
                cells.append(done ? "✅" : "❌")
            }
            lines.append(g.name + "\t" + cells.joined(separator: "\t"))
        }
        completion(lines.joined(separator: "\n"))
    }

    // MARK: - Weekly Summary

    func buildWeeklySummary(completion: @escaping (String) -> Void) {
        let goals = store.listGoals()
        let checkIns = store.checkInsForWeek(ending: Date())

        guard !goals.isEmpty else {
            completion("📊 No goals tracked this week. Add goals with /goals add [description]")
            return
        }

        // Build structured data for Claude
        let df = DateFormatter()
        df.dateFormat = "EEEE h:mm a"

        var goalData: [[String: Any]] = []
        for g in goals {
            let myCheckIns = checkIns.filter { $0.goalId == g.id }
            let entries = myCheckIns.compactMap { c -> [String: String]? in
                guard let ts = ISO8601DateFormatter().date(from: c.timestamp) else { return nil }
                var entry: [String: String] = ["time": df.string(from: ts)]
                if let n = c.note { entry["note"] = n }
                return entry
            }
            goalData.append([
                "goal": g.name,
                "frequency": g.frequency,
                "completions": entries.count,
                "target": g.frequency == "daily" ? 7 : 1,
                "entries": entries
            ])
        }

        let jsonData = (try? JSONSerialization.data(withJSONObject: goalData, options: .prettyPrinted))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let system = """
        You are NateBot generating a warm, personal weekly goal summary for Nathan.
        Write 3-6 sentences. Cover how he did on each goal, notice patterns, reference specific
        times or notes from check-in data, and end with brief encouragement for next week.
        Be warm and personal, not corporate. Use plain text (no markdown).
        """
        let userMessage = "Here are Nathan's goal check-ins for the past week:\n\(jsonData)\n\nGenerate the weekly summary."

        claude.call(system: system, userMessage: userMessage) { result in
            switch result {
            case .success(let text):
                completion("📊 Weekly Goal Summary:\n\n\(text)")
            case .failure(let err):
                completion("⚠️ Could not generate summary: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Fuzzy Match

    private func fuzzyMatch(input: String, goals: [Goal]) -> Goal? {
        let lower = input.lowercased()
        // Exact match
        if let exact = goals.first(where: { $0.name.lowercased() == lower }) {
            return exact
        }
        // Substring match (input contains goal name or vice versa)
        if let contains = goals.first(where: {
            lower.contains($0.name.lowercased()) || $0.name.lowercased().contains(lower)
        }) {
            return contains
        }
        // Stem/prefix word overlap — "scripture" matches "scriptures", "pray" matches "prayer"
        let inputWords = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var bestGoal: Goal? = nil
        var bestScore = 0
        for g in goals {
            let goalWords = g.name.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            var score = 0
            for iw in inputWords {
                for gw in goalWords {
                    if iw == gw || iw.hasPrefix(gw) || gw.hasPrefix(iw) {
                        score += 1
                    }
                }
            }
            if score > bestScore {
                bestScore = score
                bestGoal = g
            }
        }
        return bestScore > 0 ? bestGoal : nil
    }
}
