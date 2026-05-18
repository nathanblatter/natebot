import Foundation
import EventKit

// MARK: - MorningBriefing

class MorningBriefing {
    private let config: Config
    private let store: EKEventStore
    private let reply: ReplyAction
    private let log: ActivityLog
    private var scheduledTimer: Timer?
    var locationTracker: LocationTracker?
    var finforgeAction: FinForgeAction?
    var kpiManager: KPIManager?
    var timezoneManager: TimezoneManager?

    init(config: Config, store: EKEventStore, reply: ReplyAction, log: ActivityLog) {
        self.config = config
        self.store  = store
        self.reply  = reply
        self.log    = log
    }

    // MARK: - Schedule daily briefing

    func scheduleDailyBriefing() {
        guard let fireDate = nextFireDate() else {
            print("[MorningBriefing] Could not parse briefing time: \(config.briefing.time)")
            return
        }

        let delay = fireDate.timeIntervalSinceNow
        print("[MorningBriefing] Next briefing in \(Int(delay / 60)) minutes.")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.send()
            self?.scheduleDailyBriefing() // Reschedule for next day
        }
    }

    // MARK: - Schedule evening briefing

    func scheduleEveningBriefing() {
        guard let eveningTime = config.briefing.eveningTime else { return }
        guard let fireDate = nextFireDate(timeString: eveningTime) else {
            print("[MorningBriefing] Could not parse evening time: \(eveningTime)")
            return
        }

        let delay = fireDate.timeIntervalSinceNow
        print("[MorningBriefing] Next evening briefing in \(Int(delay / 60)) minutes.")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendEveningBriefing()
            self?.scheduleEveningBriefing()
        }
    }

    // MARK: - Send briefing (public, also used by /briefing command)

    func send() {
        buildBriefing { [weak self] text in
            guard let self = self else { return }
            if let finforge = self.finforgeAction {
                finforge.briefing { financeBrief in
                    let fullBriefing = text + "\n\n" + financeBrief
                    self.reply.send(fullBriefing)
                    self.log.append(from: "system", message: "morning_briefing",
                                    action: "briefing", result: "sent", reply: "Briefing sent (with finance)")
                    // Trigger KPI morning energy check-in after a short pause
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.kpiManager?.sendMorningCheckin()
                    }
                }
            } else {
                self.reply.send(text)
                self.log.append(from: "system", message: "morning_briefing",
                                action: "briefing", result: "sent", reply: "Briefing sent")
                // Trigger KPI morning energy check-in after a short pause
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.kpiManager?.sendMorningCheckin()
                }
            }
        }
    }

    /// Send evening briefing — includes location summary.
    func sendEveningBriefing() {
        buildBriefing { [weak self] text in
            guard let self = self else { return }
            var fullText = text.replacingOccurrences(
                of: "☀️ Good morning",
                with: "🌙 Good evening"
            )

            // Append location summary if tracker is available
            if let tracker = self.locationTracker {
                let summary = tracker.generateSummary()
                fullText += "\n\n📍 LOCATION SUMMARY\n\(summary)"
            }

            self.reply.send(fullText)
            self.log.append(from: "system", message: "evening_briefing",
                            action: "evening_briefing", result: "sent", reply: "Evening briefing sent")
        }
    }

    // MARK: - Build briefing content

    private func buildBriefing(completion: @escaping (String) -> Void) {
        let cal = timezoneManager?.calendar ?? Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today),
              let upcomingEnd = cal.date(byAdding: .day, value: config.briefing.upcomingDays, to: today)
        else {
            completion("⚠️ Could not build briefing — date calculation error.")
            return
        }

        let df = timezoneManager?.formatter(format: "EEEE, MMMM d") ?? {
            let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f
        }()

        // Fetch all EventKit data
        let group = DispatchGroup()

        var overdueReminders:    [EKReminder] = []
        var todayEvents:         [EKEvent]    = []
        var dueTodayReminders:   [EKReminder] = []
        var upcomingReminders:   [EKReminder] = []

        // 1. All incomplete reminders
        group.enter()
        fetchIncompleteReminders { reminders in
            overdueReminders = reminders.filter { r in
                guard let due = r.dueDateComponents?.date else { return false }
                return due < today && !r.isCompleted
            }.sorted {
                ($0.dueDateComponents?.date ?? Date()) < ($1.dueDateComponents?.date ?? Date())
            }

            dueTodayReminders = reminders.filter { r in
                guard let due = r.dueDateComponents?.date else { return false }
                return due >= today && due < tomorrow && !r.isCompleted
            }

            upcomingReminders = reminders.filter { r in
                guard let due = r.dueDateComponents?.date else { return false }
                let list = r.calendar?.title ?? ""
                let isWorkOrSchool = list == self.config.reminderLists.work ||
                                     list == self.config.reminderLists.school
                return due >= tomorrow && due <= upcomingEnd && !r.isCompleted && isWorkOrSchool
            }.sorted {
                ($0.dueDateComponents?.date ?? Date()) < ($1.dueDateComponents?.date ?? Date())
            }

            group.leave()
        }

        // 2. Today's calendar events
        group.enter()
        fetchTodayEvents(start: today, end: tomorrow) { events in
            todayEvents = events.sorted { $0.startDate < $1.startDate }
            group.leave()
        }

        group.notify(queue: .main) {
            let header = "☀️ Good morning, Nathan. Here's your day — \(df.string(from: Date()))"

            var sections: [String] = [header, ""]

            // OVERDUE
            sections.append("⚠️ OVERDUE")
            if overdueReminders.isEmpty {
                sections.append("  Nothing overdue")
            } else {
                for r in overdueReminders {
                    var line = "  • \(r.title ?? "Untitled")"
                    if let due = r.dueDateComponents?.date {
                        line += " (was due \(self.relativeDateString(due)))"
                    }
                    sections.append(line)
                }
            }
            sections.append("")

            // TODAY'S CALENDAR
            sections.append("📅 TODAY'S CALENDAR")
            if todayEvents.isEmpty {
                sections.append("  Nothing scheduled")
            } else {
                let tf = self.timezoneManager?.formatter(format: "h:mm a") ?? {
                    let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
                }()
                for e in todayEvents {
                    sections.append("  • \(tf.string(from: e.startDate)) — \(e.title ?? "Untitled")")
                }
            }
            sections.append("")

            // DUE TODAY
            sections.append("✅ DUE TODAY")
            if dueTodayReminders.isEmpty {
                sections.append("  Nothing due")
            } else {
                for r in dueTodayReminders {
                    sections.append("  • \(r.title ?? "Untitled")")
                }
            }
            sections.append("")

            // UPCOMING ASSIGNMENTS
            sections.append("📋 UPCOMING ASSIGNMENTS")
            if upcomingReminders.isEmpty {
                sections.append("  Nothing upcoming")
            } else {
                let upDf = self.timezoneManager?.formatter(format: "MMM d") ?? {
                    let f = DateFormatter(); f.dateFormat = "MMM d"; return f
                }()
                for r in upcomingReminders {
                    var line = "  • \(r.title ?? "Untitled")"
                    if let due = r.dueDateComponents?.date {
                        line += " — due \(upDf.string(from: due))"
                    }
                    sections.append(line)
                }
            }
            sections.append("")

            // Footer summary
            let n1 = overdueReminders.count
            let n2 = todayEvents.count
            let n3 = dueTodayReminders.count
            let n4 = upcomingReminders.count
            sections.append("—")
            sections.append("\(n1) overdue · \(n2) events · \(n3) due today · \(n4) upcoming")

            completion(sections.joined(separator: "\n"))
        }
    }

    // MARK: - EventKit Queries

    private func fetchIncompleteReminders(completion: @escaping ([EKReminder]) -> Void) {
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: pred) { reminders in
            completion(reminders ?? [])
        }
    }

    private func fetchTodayEvents(start: Date, end: Date, completion: @escaping ([EKEvent]) -> Void) {
        let calendars = store.calendars(for: .event)
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: pred)
        completion(events)
    }

    // MARK: - Helpers

    private func nextFireDate() -> Date? {
        nextFireDate(timeString: config.briefing.time)
    }

    private func nextFireDate(timeString: String) -> Date? {
        if let tm = timezoneManager {
            return tm.nextDailyFireDate(timeString: timeString)
        }
        // Fallback: system calendar
        let parts = timeString.components(separatedBy: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour   = hour
        components.minute = minute
        components.second = 0
        guard var fire = Calendar.current.date(from: components) else { return nil }
        if fire <= Date() {
            fire = Calendar.current.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        return fire
    }

    private func relativeDateString(_ date: Date) -> String {
        let cal = timezoneManager?.calendar ?? Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        default:
            let df = DateFormatter()
            df.dateFormat = "MMM d"
            return df.string(from: date)
        }
    }
}

// Convenience for dateComponents → Date
private extension DateComponents {
    var date: Date? {
        Calendar.current.date(from: self)
    }
}
