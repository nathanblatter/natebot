import Foundation

// MARK: - GoalReminder

class GoalReminder {
    private let config: GoalTrackingConfig
    private let store: GoalStore
    private let reply: ReplyAction
    private let log: ActivityLog
    private let goalAction: () -> GoalAction?   // lazy to avoid circular init
    private var workItems: [String: DispatchWorkItem] = [:]
    private var weeklySummaryItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.natebot.goalreminder")

    /// Set from main.swift to add location context to reminders.
    var locationTracker: LocationTracker?
    /// Set from main.swift — authoritative timezone for all fire-date computation.
    var timezoneManager: TimezoneManager?

    // goalActionProvider is a closure so GoalAction can reference GoalReminder and vice versa
    init(config: GoalTrackingConfig, store: GoalStore, reply: ReplyAction, log: ActivityLog,
         goalActionProvider: @escaping () -> GoalAction?) {
        self.config = config
        self.store  = store
        self.reply  = reply
        self.log    = log
        self.goalAction = goalActionProvider
    }

    // MARK: - Public

    func scheduleAllReminders() {
        queue.async { [weak self] in
            self?.cancelAll()
            guard let self = self else { return }
            let goals = self.store.listGoals()
            for goal in goals where goal.reminderTime != nil {
                self.scheduleDailyReminder(for: goal)
            }
            self.scheduleWeeklySummary()
        }
    }

    func reschedule() {
        scheduleAllReminders()
    }

    // MARK: - Private: Per-goal daily reminder

    private func scheduleDailyReminder(for goal: Goal) {
        guard let timeStr = goal.reminderTime,
              let fireDate = nextDailyFireDate(timeStr: timeStr) else { return }

        let delay = fireDate.timeIntervalSinceNow
        print("[GoalReminder] Scheduling reminder for '\(goal.name)' in \(Int(delay / 60)) min.")

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            let isDone: Bool
            if goal.frequency == "weekly" {
                isDone = self.store.isCompletedThisWeek(goalId: goal.id)
            } else {
                isDone = self.store.isCompletedToday(goalId: goal.id)
            }

            if !isDone {
                var msg = "⏰ Reminder: \(goal.name) — not done yet today!"
                // Add location context if available
                if let tracker = self.locationTracker, let latest = tracker.latestEntry() {
                    let where_ = latest.label ?? latest.address
                    msg += " (You're at \(where_))"
                }
                self.reply.send(msg)
                self.log.append(from: "system", message: "goal_reminder",
                                action: "goal_reminder", result: "sent", reply: msg)
            }

            // Reschedule for next day
            self.queue.async { [weak self] in
                self?.scheduleDailyReminder(for: goal)
            }
        }

        workItems[goal.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Private: Weekly summary

    private func scheduleWeeklySummary() {
        guard let fireDate = nextWeeklySummaryDate() else { return }
        let delay = fireDate.timeIntervalSinceNow
        print("[GoalReminder] Weekly summary in \(Int(delay / 60)) min.")

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.goalAction()?.buildWeeklySummary { summary in
                self.reply.send(summary)
                self.log.append(from: "system", message: "weekly_goal_summary",
                                action: "goal_summary", result: "sent", reply: "Summary sent")
            }
            // Reschedule for next week
            self.queue.async { [weak self] in
                self?.scheduleWeeklySummary()
            }
        }

        weeklySummaryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Cancel

    private func cancelAll() {
        workItems.values.forEach { $0.cancel() }
        workItems.removeAll()
        weeklySummaryItem?.cancel()
        weeklySummaryItem = nil
    }

    // MARK: - Date helpers

    private func nextDailyFireDate(timeStr: String) -> Date? {
        if let tm = timezoneManager {
            return tm.nextDailyFireDate(timeString: timeStr)
        }
        let parts = timeStr.components(separatedBy: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard var fire = Calendar.current.date(from: comps) else { return nil }
        if fire <= Date() {
            fire = Calendar.current.date(byAdding: .day, value: 1, to: fire) ?? fire
        }
        return fire
    }

    private func nextWeeklySummaryDate() -> Date? {
        let parts = config.weeklySummaryTime.components(separatedBy: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }

        let cal = timezoneManager?.calendar ?? Calendar.current
        let targetWeekday = config.weeklySummaryDay + 1  // Calendar: 1=Sunday

        var comps = DateComponents()
        comps.weekday = targetWeekday
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        guard let next = cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) else {
            return nil
        }
        return next
    }
}
