import Foundation
import EventKit

// MARK: - ReminderAction

class ReminderAction {
    let store: EKEventStore
    let config: Config
    let claude: ClaudeAPI

    init(store: EKEventStore, config: Config, claude: ClaudeAPI) {
        self.store = store
        self.config = config
        self.claude = claude
    }

    // MARK: - Add Single Reminder

    func addReminder(details: String, completion: @escaping (String) -> Void) {
        let now = ISO8601DateFormatter().string(from: Date())
        let systemPrompt = """
        Parse the following text into a reminder. Return compact JSON only.

        Format: {"title":"string","due_date":"ISO8601 or null","priority":"none|low|medium|high","list":"default|work|school"}

        Rules:
        - Current date/time: \(now)
        - Infer the most appropriate reminder list:
            "work" → work tasks, meetings, professional items
            "school" → assignments, exams, class-related items
            "default" → personal, household, general
        - Use format "2026-03-15T14:00:00" or null for no due date.
        - Default priority: "none".
        """

        claude.call(system: systemPrompt, userMessage: details) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                completion("⚠️ NLP routing failed. Try: /remind [title] [date]")
            case .success(let text):
                guard let reminder = self.parseReminderJSON(text) else {
                    completion("⚠️ Could not parse reminder. Try: /remind call mom tomorrow")
                    return
                }
                self.createEKReminder(reminder, completion: completion)
            }
        }
    }

    // MARK: - Bulk Parse

    func bulkParse(text: String, completion: @escaping (String) -> Void) {
        let now = ISO8601DateFormatter().string(from: Date())
        let systemPrompt = """
        Extract ALL reminders/tasks from the following text. Return a compact JSON array only.

        Format: [{"title":"string","due_date":"ISO8601 or null","priority":"none|low|medium|high","list":"default|work|school"}]

        Rules:
        - Current date/time: \(now)
        - Route each item to the most appropriate list (work/school/default).
        - Include every task, assignment, or to-do you can find.
        - If none found, return [].
        """

        claude.call(system: systemPrompt, userMessage: text, maxTokens: 8192) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                completion("⚠️ NLP routing failed.")
            case .success(let responseText):
                let reminders = self.parseReminderArray(responseText)
                if reminders.isEmpty {
                    completion("⚠️ No reminders found in that text.")
                    return
                }

                var created = 0
                var failed  = 0
                var listsUsed = Set<String>()
                let group = DispatchGroup()

                for reminder in reminders {
                    group.enter()
                    self.createEKReminder(reminder) { msg in
                        if msg.hasPrefix("✅") {
                            created += 1
                            listsUsed.insert(reminder.list)
                        } else {
                            failed += 1
                        }
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    let lists = listsUsed.sorted().joined(separator: ", ")
                    var reply = "📋 Created \(created) reminder\(created == 1 ? "" : "s") across \(lists.isEmpty ? "default" : lists)."
                    if failed > 0 { reply += " (\(failed) failed)" }
                    completion(reply)
                }
            }
        }
    }

    // MARK: - Private: reminder data model

    private struct ReminderData {
        let title: String
        let dueDate: Date?
        let priority: EKReminderPriority
        let list: String   // "default" | "work" | "school"
    }

    private func parseReminderJSON(_ text: String) -> ReminderData? {
        guard let jsonStr = text.extractJSONObject(),
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else { return nil }

        let dueDateStr = json["due_date"] as? String
        let dueDate = dueDateStr.flatMap { Date.fromClaudeString($0) }
        let priorityStr = json["priority"] as? String ?? "none"
        let listStr = json["list"] as? String ?? "default"

        return ReminderData(
            title: title,
            dueDate: dueDate,
            priority: parsePriority(priorityStr),
            list: listStr
        )
    }

    private func parseReminderArray(_ text: String) -> [ReminderData] {
        guard let jsonStr = text.extractJSONArray(),
              let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return array.compactMap { json -> ReminderData? in
            guard let title = json["title"] as? String else { return nil }
            let dueDateStr = json["due_date"] as? String
            let dueDate = dueDateStr.flatMap { Date.fromClaudeString($0) }
            let priorityStr = json["priority"] as? String ?? "none"
            let listStr = json["list"] as? String ?? "default"

            return ReminderData(
                title: title,
                dueDate: dueDate,
                priority: parsePriority(priorityStr),
                list: listStr
            )
        }
    }

    private func parsePriority(_ s: String) -> EKReminderPriority {
        switch s.lowercased() {
        case "high":   return .high
        case "medium": return .medium
        case "low":    return .low
        default:       return .none
        }
    }

    // MARK: - Private: EventKit

    private func createEKReminder(_ reminder: ReminderData, completion: @escaping (String) -> Void) {
        // Resolve list name
        let listName: String
        switch reminder.list {
        case "work":   listName = config.reminderLists.work
        case "school": listName = config.reminderLists.school
        default:       listName = config.reminderLists.defaultList
        }

        // Find or use default list
        let ekList: EKCalendar? = store.calendars(for: .reminder)
            .first(where: { $0.title == listName })
            ?? store.defaultCalendarForNewReminders()

        guard let ekList = ekList else {
            completion("⚠️ No reminder list found. Check EventKit access.")
            return
        }

        let ekReminder = EKReminder(eventStore: store)
        ekReminder.title    = reminder.title
        ekReminder.calendar = ekList
        ekReminder.priority = Int(reminder.priority.rawValue)

        if let dueDate = reminder.dueDate {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: dueDate
            )
            ekReminder.dueDateComponents = components
        }

        do {
            try store.save(ekReminder, commit: true)
            var reply = "✅ Reminder set: '\(reminder.title)'"
            if let dueDate = reminder.dueDate {
                let df = DateFormatter()
                df.dateFormat = "MMM d 'at' h:mm a"
                reply += " — due \(df.string(from: dueDate))"
            }
            completion(reply)
        } catch {
            completion("⚠️ Failed to save reminder '\(reminder.title)': \(error.localizedDescription)")
        }
    }
}
