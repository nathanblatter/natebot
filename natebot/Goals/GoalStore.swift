import Foundation

// MARK: - Models

struct Goal: Codable {
    let id: String
    var name: String
    var frequency: String   // "daily" | "weekly"
    var reminderTime: String? // "08:00" or nil
    var location: String?     // named location for auto-check-in (e.g. "Gym")
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, frequency, location
        case reminderTime = "reminder_time"
        case createdAt = "created_at"
    }
}

struct GoalCheckIn: Codable {
    let id: String
    let goalId: String
    let timestamp: String
    let source: String  // "nlp" | "slash"
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case goalId = "goal_id"
        case timestamp, source, note
    }
}

// MARK: - GoalStore

class GoalStore {
    private let goalsURL: URL
    private let checkInsURL: URL
    private var goals: [Goal] = []
    private var checkIns: [GoalCheckIn] = []
    private let queue = DispatchQueue(label: "com.natebot.goalstore", attributes: .concurrent)

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("NateBot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.goalsURL     = dir.appendingPathComponent("goals.json")
        self.checkInsURL  = dir.appendingPathComponent("goal_checkins.json")
        loadAll()
    }

    // MARK: - Goal CRUD

    @discardableResult
    func addGoal(name: String, frequency: String, reminderTime: String?, location: String? = nil) -> Goal {
        let goal = Goal(
            id: UUID().uuidString,
            name: name,
            frequency: frequency,
            reminderTime: reminderTime,
            location: location,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        queue.async(flags: .barrier) {
            self.goals.append(goal)
            self.persistGoals()
        }
        return goal
    }

    @discardableResult
    func removeGoal(id: String) -> Bool {
        var removed = false
        queue.sync(flags: .barrier) {
            let before = self.goals.count
            self.goals.removeAll { $0.id == id }
            removed = self.goals.count < before
            if removed { self.persistGoals() }
        }
        return removed
    }

    func listGoals() -> [Goal] {
        queue.sync { goals }
    }

    // MARK: - Check-ins

    func log(goalId: String, source: String, note: String?) {
        let checkIn = GoalCheckIn(
            id: UUID().uuidString,
            goalId: goalId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            source: source,
            note: note
        )
        queue.async(flags: .barrier) {
            self.checkIns.append(checkIn)
            self.persistCheckIns()
        }
    }

    func isCompletedToday(goalId: String, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: Date())
        return queue.sync {
            checkIns.contains { c in
                c.goalId == goalId &&
                (ISO8601DateFormatter().date(from: c.timestamp).map { $0 >= today } ?? false)
            }
        }
    }

    func isCompletedThisWeek(goalId: String, calendar: Calendar = .current) -> Bool {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else {
            return false
        }
        return queue.sync {
            checkIns.contains { c in
                c.goalId == goalId &&
                (ISO8601DateFormatter().date(from: c.timestamp).map { $0 >= weekStart } ?? false)
            }
        }
    }

    func listAllCheckIns() -> [GoalCheckIn] {
        queue.sync { checkIns }
    }

    func checkInsForWeek(ending end: Date) -> [GoalCheckIn] {
        guard let start = Calendar.current.date(byAdding: .day, value: -7, to: end) else { return [] }
        return queue.sync {
            checkIns.filter { c in
                guard let ts = ISO8601DateFormatter().date(from: c.timestamp) else { return false }
                return ts >= start && ts <= end
            }
        }
    }

    // MARK: - Persistence

    private func loadAll() {
        if let data = try? Data(contentsOf: goalsURL),
           let loaded = try? JSONDecoder().decode([Goal].self, from: data) {
            goals = loaded
        }
        if let data = try? Data(contentsOf: checkInsURL),
           let loaded = try? JSONDecoder().decode([GoalCheckIn].self, from: data) {
            checkIns = loaded
        }
    }

    private func persistGoals() {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        try? data.write(to: goalsURL, options: .atomic)
    }

    private func persistCheckIns() {
        guard let data = try? JSONEncoder().encode(checkIns) else { return }
        try? data.write(to: checkInsURL, options: .atomic)
    }
}
