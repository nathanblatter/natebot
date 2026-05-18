import Foundation
import EventKit

// MARK: - CalendarAction

class CalendarAction {
    let store: EKEventStore
    let config: Config
    let claude: ClaudeAPI
    var timezoneManager: TimezoneManager?

    init(store: EKEventStore, config: Config, claude: ClaudeAPI) {
        self.store = store
        self.config = config
        self.claude = claude
    }

    /// Current date/time formatted in the authoritative timezone for Claude's "now" reference.
    private var nowString: String {
        if let tm = timezoneManager {
            return tm.formatter(format: "yyyy-MM-dd'T'HH:mm:ssZZZZZ").string(from: Date())
        }
        return ISO8601DateFormatter().string(from: Date())
    }

    /// Parse a no-timezone date string from Claude using the authoritative timezone.
    private func parseDate(_ s: String) -> Date? {
        let tz = timezoneManager?.currentTimezone ?? TimeZone.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        // Try standard ISO8601 (has timezone offset already)
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }

    // MARK: - Add Single Event

    func addEvent(details: String, completion: @escaping (String) -> Void) {
        let now = nowString
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
                completion(self.createEKEvent(event))
            }
        }
    }

    // MARK: - Bulk Parse

    func bulkParse(text: String, completion: @escaping (String) -> Void) {
        let now = nowString
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

                for event in events {
                    let msg = self.createEKEvent(event)
                    if msg.hasPrefix("✅") { created += 1 } else { failed += 1 }
                }

                var reply = "📅 Created \(created) calendar event\(created == 1 ? "" : "s")."
                if failed > 0 { reply += " (\(failed) failed)" }
                completion(reply)
            }
        }
    }

    // MARK: - List Upcoming Events

    func listUpcomingEvents(days: Int, completion: @escaping ([[String: Any]]) -> Void) {
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else {
            completion([]); return
        }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        let df = ISO8601DateFormatter()
        let result: [[String: Any]] = events.map { e in
            var d: [String: Any] = [
                "id": e.eventIdentifier ?? "",
                "title": e.title ?? "Untitled",
                "startDate": df.string(from: e.startDate),
                "endDate": df.string(from: e.endDate),
                "calendar": e.calendar?.title ?? ""
            ]
            if let loc = e.location { d["location"] = loc }
            if let notes = e.notes { d["notes"] = notes }
            return d
        }
        completion(result)
    }

    // MARK: - Delete Event

    func deleteEvent(eventId: String, completion: @escaping (Bool, String) -> Void) {
        guard let event = store.event(withIdentifier: eventId) else {
            completion(false, "Event not found"); return
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            completion(true, "Deleted")
        } catch {
            completion(false, error.localizedDescription)
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
              let start = parseDate(startStr),
              let end   = parseDate(endStr) else { return nil }

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
                  let start    = parseDate(startStr),
                  let end      = parseDate(endStr) else { return nil }
            return EventData(title: title, startDate: start, endDate: end,
                             location: json["location"] as? String,
                             notes: json["notes"] as? String)
        }
    }

    // MARK: - Private: EventKit

    @discardableResult
    private func createEKEvent(_ event: EventData) -> String {
        let calName = config.calendars.defaultCalendar
        let calendar = store.calendars(for: .event).first(where: { $0.title == calName })
                    ?? store.defaultCalendarForNewEvents

        guard let calendar = calendar else {
            return "⚠️ No writable calendar found. Check EventKit access."
        }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title     = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate   = event.endDate
        ekEvent.location  = event.location
        ekEvent.notes     = event.notes
        ekEvent.calendar  = calendar

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
            let df = timezoneManager?.formatter(format: "MMM d 'at' h:mm a") ?? {
                let f = DateFormatter(); f.dateFormat = "MMM d 'at' h:mm a"; return f
            }()
            return "✅ Added '\(event.title)' to calendar — \(df.string(from: event.startDate))"
        } catch {
            return "⚠️ Failed to save '\(event.title)': \(error.localizedDescription)"
        }
    }
}
