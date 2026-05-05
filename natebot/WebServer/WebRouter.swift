import Foundation
import NIOHTTP1

// MARK: - WebRouter
// Dispatches HTTP method + path to handlers.

final class WebRouter {
    private let configManager: ConfigManager
    private let log: ActivityLog
    private let goalStore: GoalStore?
    private let locationTracker: LocationTracker?
    private let calendarAction: CalendarAction
    private let reminderAction: ReminderAction
    private let statusAction: StatusAction
    private let systemAction: SystemAction

    typealias ResponseCallback = (_ statusCode: Int, _ headers: [(String, String)], _ body: Data) -> Void

    init(
        configManager: ConfigManager,
        log: ActivityLog,
        goalStore: GoalStore?,
        locationTracker: LocationTracker?,
        calendarAction: CalendarAction,
        reminderAction: ReminderAction,
        statusAction: StatusAction,
        systemAction: SystemAction
    ) {
        self.configManager   = configManager
        self.log             = log
        self.goalStore       = goalStore
        self.locationTracker = locationTracker
        self.calendarAction  = calendarAction
        self.reminderAction  = reminderAction
        self.statusAction    = statusAction
        self.systemAction    = systemAction
    }

    // MARK: - Dispatch

    func handle(head: HTTPRequestHead, body: Data, completion: @escaping ResponseCallback) {
        let method = head.method
        let uri    = head.uri
        let path   = uri.components(separatedBy: "?").first ?? uri
        let query  = uri.contains("?") ? String(uri.dropFirst(path.count + 1)) : ""

        // CORS + JSON headers for all API responses
        func json(_ obj: Any, status: Int = 200) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else {
                completion(500, [("content-type", "application/json")], Data("{\"error\":\"encode failed\"}".utf8))
                return
            }
            completion(status, [("content-type", "application/json")], data)
        }

        func errResp(_ msg: String, status: Int = 400) {
            let safe = msg.replacingOccurrences(of: "\"", with: "'")
            let data = Data("{\"error\":\"\(safe)\"}".utf8)
            completion(status, [("content-type", "application/json")], data)
        }

        func ok(_ msg: String = "ok") {
            json(["status": msg])
        }

        // ── SPA ──────────────────────────────────────────────────────────────
        if method == .GET && path == "/" {
            let html = WebUI.html
            completion(200, [("content-type", "text/html; charset=utf-8")], Data(html.utf8))
            return
        }

        // ── Config ───────────────────────────────────────────────────────────
        if path == "/api/config" {
            if method == .GET {
                guard let data = try? JSONEncoder().encode(configManager.current) else { errResp("encode failed"); return }
                completion(200, [("content-type", "application/json")], data)
                return
            }
            if method == .PUT {
                guard let newConfig = try? JSONDecoder().decode(Config.self, from: body) else {
                    errResp("invalid config JSON"); return
                }
                do {
                    try configManager.save(newConfig)
                    ok("saved")
                } catch {
                    errResp("save failed: \(error.localizedDescription)", status: 500)
                }
                return
            }
        }

        // ── Activity Log ─────────────────────────────────────────────────────
        if method == .GET && path == "/api/log" {
            let count = queryInt(query, key: "count") ?? 50
            let entries = log.recent(count: count)
            let arr = entries.map { e -> [String: String] in
                ["timestamp": e.timestamp, "from": e.from, "message": e.message,
                 "action": e.action, "result": e.result, "reply": e.reply]
            }
            json(arr)
            return
        }

        // ── Goals ─────────────────────────────────────────────────────────────
        if path == "/api/goals" {
            if method == .GET {
                guard let gs = goalStore else { json([]); return }
                let goals = gs.listGoals().map { g -> [String: Any] in
                    var d: [String: Any] = ["id": g.id, "name": g.name, "frequency": g.frequency, "created_at": g.createdAt]
                    if let t = g.reminderTime { d["reminder_time"] = t }
                    if let loc = g.location { d["location"] = loc }
                    return d
                }
                json(goals)
                return
            }
            if method == .POST {
                guard let gs = goalStore,
                      let body = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let name = body["name"] as? String,
                      let freq = body["frequency"] as? String else {
                    errResp("missing name or frequency"); return
                }
                let rt = body["reminder_time"] as? String
                let loc = body["location"] as? String
                let goal = gs.addGoal(name: name, frequency: freq, reminderTime: rt, location: loc)
                json(["id": goal.id, "name": goal.name, "frequency": goal.frequency])
                return
            }
        }

        if path == "/api/goals/checkins" && method == .GET {
            guard let gs = goalStore else { json([]); return }
            let checkins = gs.listAllCheckIns().map { c -> [String: Any] in
                var d: [String: Any] = ["id": c.id, "goal_id": c.goalId,
                                        "timestamp": c.timestamp, "source": c.source]
                if let n = c.note { d["note"] = n }
                return d
            }
            json(checkins)
            return
        }

        // /api/goals/:id  (DELETE)
        if method == .DELETE && path.hasPrefix("/api/goals/") && !path.hasPrefix("/api/goals/checkins") {
            let id = String(path.dropFirst("/api/goals/".count))
            guard let gs = goalStore else { errResp("goal tracking disabled"); return }
            if gs.removeGoal(id: id) { ok() } else { errResp("not found", status: 404) }
            return
        }

        // /api/goals/:id/checkin  (POST)
        if method == .POST && path.hasSuffix("/checkin") && path.hasPrefix("/api/goals/") {
            let middle = path.dropFirst("/api/goals/".count).dropLast("/checkin".count)
            let goalId = String(middle)
            guard let gs = goalStore else { errResp("goal tracking disabled"); return }
            let note = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["note"] as? String
            gs.log(goalId: goalId, source: "webui", note: note)
            ok()
            return
        }

        // ── Status ────────────────────────────────────────────────────────────
        if method == .GET && path == "/api/status" {
            let apps = configManager.current.apps
            let group = DispatchGroup()
            var results: [[String: Any]] = []
            let lock = NSLock()
            for app in apps {
                group.enter()
                statusAction.checkHealth(app: app) { isUp, detail in
                    lock.lock()
                    var d: [String: Any] = ["name": app.name, "displayName": app.displayName, "isUp": isUp]
                    if let det = detail { d["detail"] = det }
                    results.append(d)
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) { json(results) }
            return
        }

        if method == .GET && path == "/api/status/system" {
            let cpu = SystemAction.getCPUUsage()
            let (ramUsed, ramTotal) = SystemAction.getRAMUsage()
            let (diskUsed, diskTotal) = SystemAction.getDiskUsage()
            json([
                "cpuPercent": cpu,
                "ramUsedGB": ramUsed, "ramTotalGB": ramTotal,
                "diskUsedGB": diskUsed, "diskTotalGB": diskTotal
            ])
            return
        }

        if method == .GET && path == "/api/status/docker" {
            SystemAction.getDockerStatuses { containers in
                let arr = containers.map { c -> [String: Any] in
                    ["name": c.name, "status": c.status, "isRunning": c.isRunning]
                }
                json(arr)
            }
            return
        }

        // ── Calendar ──────────────────────────────────────────────────────────
        if path == "/api/calendar/events" {
            if method == .GET {
                let days = queryInt(query, key: "days") ?? 14
                calendarAction.listUpcomingEvents(days: days) { events in json(events) }
                return
            }
            if method == .POST {
                guard let b = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let details = b["details"] as? String else { errResp("missing details"); return }
                calendarAction.addEvent(details: details) { reply in
                    json(["reply": reply])
                }
                return
            }
        }

        // /api/calendar/events/:id  (DELETE)
        if method == .DELETE && path.hasPrefix("/api/calendar/events/") {
            let eventId = String(path.dropFirst("/api/calendar/events/".count))
            calendarAction.deleteEvent(eventId: eventId) { success, msg in
                if success { json(["status": "deleted"]) } else { errResp(msg, status: 404) }
            }
            return
        }

        // ── Reminders ─────────────────────────────────────────────────────────
        if path == "/api/reminders" {
            if method == .GET {
                reminderAction.listReminders { reminders in json(reminders) }
                return
            }
            if method == .POST {
                guard let b = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let details = b["details"] as? String else { errResp("missing details"); return }
                reminderAction.addReminder(details: details) { reply in
                    json(["reply": reply])
                }
                return
            }
        }

        // /api/reminders/:id/complete  (PUT)
        if method == .PUT && path.hasSuffix("/complete") && path.hasPrefix("/api/reminders/") {
            let mid = path.dropFirst("/api/reminders/".count).dropLast("/complete".count)
            reminderAction.completeReminder(reminderId: String(mid)) { success, msg in
                if success { ok() } else { errResp(msg, status: 404) }
            }
            return
        }

        // /api/reminders/:id  (DELETE)
        if method == .DELETE && path.hasPrefix("/api/reminders/") && !path.hasSuffix("/complete") {
            let reminderId = String(path.dropFirst("/api/reminders/".count))
            reminderAction.deleteReminder(reminderId: reminderId) { success, msg in
                if success { ok() } else { errResp(msg, status: 404) }
            }
            return
        }

        // ── Location ─────────────────────────────────────────────────────────
        if method == .GET && path == "/api/location/current" {
            guard let tracker = locationTracker else { json(["error": "location tracking disabled"]); return }
            if let entry = tracker.latestEntry() {
                var d: [String: Any] = ["device": entry.device, "address": entry.address, "timestamp": entry.timestamp]
                if let label = entry.label { d["label"] = label }
                if let lat = entry.latitude { d["latitude"] = lat }
                if let lon = entry.longitude { d["longitude"] = lon }
                json(d)
            } else {
                json(["error": "no location data"])
            }
            return
        }

        if method == .GET && path == "/api/location/history" {
            guard let tracker = locationTracker else { json([]); return }
            let dateStr = queryString(query, key: "date") ?? todayDateString()
            let history = tracker.entries(for: dateStr)
            let arr = history.map { e -> [String: Any] in
                var d: [String: Any] = ["device": e.device, "address": e.address, "timestamp": e.timestamp]
                if let label = e.label { d["label"] = label }
                if let lat = e.latitude { d["latitude"] = lat }
                if let lon = e.longitude { d["longitude"] = lon }
                return d
            }
            json(arr)
            return
        }

        if method == .POST && path == "/api/location/scrape" {
            guard let tracker = locationTracker else { errResp("location tracking disabled"); return }
            tracker.scrapeNow { entry in
                if let e = entry {
                    var d: [String: Any] = ["status": "ok", "device": e.device, "address": e.address, "timestamp": e.timestamp]
                    if let label = e.label { d["label"] = label }
                    if let lat = e.latitude { d["latitude"] = lat }
                    if let lon = e.longitude { d["longitude"] = lon }
                    json(d)
                } else {
                    errResp("scrape failed — device not found or Find My not running")
                }
            }
            return
        }

        // ── 404 ───────────────────────────────────────────────────────────────
        errResp("not found", status: 404)
    }

    // MARK: - Helpers

    private func queryInt(_ query: String, key: String) -> Int? {
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == key { return Int(kv[1]) }
        }
        return nil
    }

    private func queryString(_ query: String, key: String) -> String? {
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == key { return kv[1] }
        }
        return nil
    }

    private func todayDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

}
