import Foundation
import EventKit

// MARK: - CalendarAction

class CalendarAction {
    let store: EKEventStore
    let config: Config
    let claude: ClaudeAPI

    init(store: EKEventStore, config: Config, claude: ClaudeAPI) {
        self.store = store
        self.config = config
        self.claude = claude
    }

    // MARK: - Add Single Event

    func addEvent(details: String, completion: @escaping (String) -> Void) {
        let now = ISO8601DateFormatter().string(from: Date())
        let systemPrompt = """
        Parse the following text into a single calendar event. Return compact JSON only — no \
        explanation, no markdown.

        Format: {"title":"string","start_date":"ISO8601","end_date":"ISO8601","location":"string or null","notes":"string or null"}

        Rules:
        - Current date/time (reference): \(now)
        - If only a date is given, use 09:00 as the start time.
        - Default duration: 60 minutes unless specified.
        - Use format "2026-03-15T14:00:00" (no timezone suffix).
        - If the event is "this Friday", infer the next upcoming Friday.
        """

        claude.call(system: systemPrompt, userMessage: details) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                completion("⚠️ NLP routing failed. Try: /cal add [title] [date] [time]")
            case .success(let text):
                guard let event = self.parseEventJSON(text) else {
                    completion("⚠️ Could not parse event details. Try: /cal add dentist Friday 2pm")
                    return
                }
                self.createEKEvent(event, completion: completion)
            }
        }
    }

    // MARK: - Bulk Parse

    func bulkParse(text: String, completion: @escaping (String) -> Void) {
        let now = ISO8601DateFormatter().string(from: Date())
        let systemPrompt = """
        Extract ALL calendar events from the following text. Return a compact JSON array only.

        Format: [{"title":"string","start_date":"ISO8601","end_date":"ISO8601","location":"string or null","notes":"string or null"}]

        Rules:
        - Current date/time: \(now)
        - Default duration: 60 minutes.
        - Use format "2026-03-15T14:00:00".
        - Include every event you can find.
        - If no events found, return [].
        """

        claude.call(system: systemPrompt, userMessage: text, maxTokens: 8192) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                completion("⚠️ NLP routing failed.")
            case .success(let responseText):
                let events = self.parseEventArray(responseText)
                if events.isEmpty {
                    completion("⚠️ No calendar events found in that text.")
                    return
                }
                var created = 0
                var failed  = 0
                let group = DispatchGroup()

                for event in events {
                    group.enter()
                    self.createEKEvent(event) { msg in
                        if msg.hasPrefix("✅") { created += 1 } else { failed += 1 }
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    var reply = "📅 Created \(created) calendar event\(created == 1 ? "" : "s")."
                    if failed > 0 { reply += " (\(failed) failed)" }
                    completion(reply)
                }
            }
        }
    }

    // MARK: - Private: event data model

    private struct EventData {
        let title: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let notes: String?
    }

    private func parseEventJSON(_ text: String) -> EventData? {
        guard let jsonStr = text.extractJSONObject(),
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let startStr = json["start_date"] as? String,
              let endStr   = json["end_date"] as? String,
              let start = Date.fromClaudeString(startStr),
              let end   = Date.fromClaudeString(endStr) else { return nil }

        return EventData(
            title: title,
            startDate: start,
            endDate: end,
            location: json["location"] as? String,
            notes: json["notes"] as? String
        )
    }

    private func parseEventArray(_ text: String) -> [EventData] {
        guard let jsonStr = text.extractJSONArray(),
              let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return array.compactMap { json -> EventData? in
            guard let title    = json["title"] as? String,
                  let startStr = json["start_date"] as? String,
                  let endStr   = json["end_date"] as? String,
                  let start    = Date.fromClaudeString(startStr),
                  let end      = Date.fromClaudeString(endStr) else { return nil }
            return EventData(title: title, startDate: start, endDate: end,
                             location: json["location"] as? String,
                             notes: json["notes"] as? String)
        }
    }

    // MARK: - Private: EventKit

    private func createEKEvent(_ event: EventData, completion: @escaping (String) -> Void) {
        let calName = config.calendars.defaultCalendar

        // Find configured calendar, fall back to default
        let calendar = store.calendars(for: .event).first(where: { $0.title == calName })
                    ?? store.defaultCalendarForNewEvents

        guard let calendar = calendar else {
            completion("⚠️ No writable calendar found. Check EventKit access.")
            return
        }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title    = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate   = event.endDate
        ekEvent.location  = event.location
        ekEvent.notes     = event.notes
        ekEvent.calendar  = calendar

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
            let df = DateFormatter()
            df.dateFormat = "MMM d 'at' h:mm a"
            completion("✅ Added '\(event.title)' to calendar — \(df.string(from: event.startDate))")
        } catch {
            completion("⚠️ Failed to save '\(event.title)': \(error.localizedDescription)")
        }
    }
}
