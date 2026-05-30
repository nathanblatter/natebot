// NateBot — macOS iMessage Automation Daemon
// Runs as a launchd agent; listens for iMessages and executes macOS actions
// via Claude API as the reasoning engine.

import Foundation
import EventKit
import Darwin

// Disable stdout buffering so launchd log files get output immediately
setbuf(stdout, nil)

// MARK: - Boot

print("[NateBot] Starting up...")

// 1. Load config + URL
let configManager: ConfigManager
do {
    let (config, url) = try ConfigLoader.loadWithURL()
    configManager = ConfigManager(config: config, configURL: url)
    print("[NateBot] Config loaded. Trusted sender: \(config.trustedSender)")
} catch ConfigError.notFound {
    print("[NateBot] FATAL: natebot.json not found. Place it at ~/.config/natebot/natebot.json or next to the executable.")
    exit(1)
} catch ConfigError.invalid(let msg) {
    print("[NateBot] FATAL: Config parse error — \(msg)")
    exit(1)
} catch {
    print("[NateBot] FATAL: \(error)")
    exit(1)
}

// 2. Initialize shared services
let log        = ActivityLog(maxEntries: configManager.current.log.maxEntries)
let claude     = ClaudeAPI(apiKey: configManager.current.claudeApiKey)
let replyAction = ReplyAction(trustedSender: configManager.current.trustedSender, log: log)

// Timezone manager — authoritative timezone for the entire daemon
let timezoneManager = TimezoneManager(claude: claude)

// 3. Request EventKit access (Calendar + Reminders)
let eventStore = EKEventStore()

func requestEventKitAccess(completion: @escaping (Bool) -> Void) {
    var calGranted: Bool  = false
    var remGranted: Bool  = false
    let group = DispatchGroup()

    group.enter()
    if #available(macOS 14.0, *) {
        eventStore.requestFullAccessToEvents { granted, _ in
            calGranted = granted
            group.leave()
        }
    } else {
        eventStore.requestAccess(to: .event) { granted, _ in
            calGranted = granted
            group.leave()
        }
    }

    group.enter()
    if #available(macOS 14.0, *) {
        eventStore.requestFullAccessToReminders { granted, _ in
            remGranted = granted
            group.leave()
        }
    } else {
        eventStore.requestAccess(to: .reminder) { granted, _ in
            remGranted = granted
            group.leave()
        }
    }

    group.notify(queue: .main) {
        completion(calGranted && remGranted)
    }
}

// 4. Action handlers
let calendarAction = CalendarAction(store: eventStore, config: configManager.current, claude: claude)
let reminderAction = ReminderAction(store: eventStore, config: configManager.current, claude: claude)
let statusAction   = StatusAction(apps: configManager.current.apps)
let systemAction   = SystemAction(config: configManager.current, reply: replyAction)

// Goal tracking (optional — enabled via goal_tracking config)
var goalAction: GoalAction? = nil
var goalReminder: GoalReminder? = nil
var sharedGoalStore: GoalStore? = nil

if let trackingConfig = configManager.current.goalTracking, trackingConfig.enabled {
    let goalStore = GoalStore()
    sharedGoalStore = goalStore
    var goalActionBox: GoalAction? = nil
    let reminder = GoalReminder(
        config: trackingConfig,
        store: goalStore,
        reply: replyAction,
        log: log,
        goalActionProvider: { goalActionBox }
    )
    let action = GoalAction(store: goalStore, claude: claude, reply: replyAction, reminder: reminder)
    goalActionBox = action
    goalAction = action
    goalReminder = reminder
}

// 5. Location tracking (optional — enabled via location_tracking config)
var locationTracker: LocationTracker? = nil

if let locConfig = configManager.current.locationTracking, locConfig.enabled {
    locationTracker = LocationTracker(
        dbURL: configManager.current.kpi?.dbUrl ?? "",
        device: locConfig.device,
        namedLocations: locConfig.namedLocations
    )
}

// 6. FinForge integration (optional — enabled via finforge config)
var finforgeAction: FinForgeAction? = nil
if let fc = configManager.current.finforge, fc.enabled {
    finforgeAction = FinForgeAction(config: fc, reply: replyAction, log: log)
    print("[Boot] FinForge integration enabled — polling \(fc.apiUrl)")
}

// 6b. KPI tracking (optional — enabled via kpi config)
var kpiManager: KPIManager? = nil
if let kc = configManager.current.kpi, kc.enabled {
    kpiManager = KPIManager(config: kc, claude: claude, reply: replyAction, log: log)
    print("[Boot] KPI tracking enabled — ingest at \(kc.apiUrl)")
}

// 7. Routers
let commandRouter  = CommandRouter()
let nlpRouter      = NLPRouter(claude: claude)

// 8. Proactive monitors + morning briefing
let proactiveMonitor = ProactiveMonitor(
    config: configManager.current,
    statusAction: statusAction,
    systemAction: systemAction,
    reply: replyAction,
    log: log
)
let morningBriefing = MorningBriefing(
    config: configManager.current,
    store: eventStore,
    reply: replyAction,
    log: log
)

// MARK: - Message Dispatcher

/// Dispatches a parsed command to the appropriate action handler.
func dispatch(_ command: ParsedCommand, rawMessage: String) {
    let config = configManager.current
    switch command {

    // MARK: Calendar
    case .calAdd(let details):
        calendarAction.addEvent(details: details) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "cal_add", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    case .calParse(let text):
        calendarAction.bulkParse(text: text) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "cal_parse", result: "ok", reply: reply)
        }

    // MARK: Reminders
    case .remindAdd(let details):
        reminderAction.addReminder(details: details) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "remind_add", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    case .remindParse(let text):
        reminderAction.bulkParse(text: text) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "remind_parse", result: "ok", reply: reply)
        }

    // MARK: Status
    case .statusAll:
        statusAction.allApps { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "status_all", result: "ok", reply: reply)
        }

    case .statusSingle(let name):
        statusAction.singleApp(name: name) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "status_single", result: "ok", reply: reply)
        }

    // MARK: System
    case .sysHealth:
        systemAction.systemHealth { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "sys_health", result: "ok", reply: reply)
        }

    case .dockerStatus:
        systemAction.dockerStatus { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "docker_status", result: "ok", reply: reply)
        }

    case .dockerStop(let container, let passphrase):
        systemAction.dockerStop(containerName: container, passphrase: passphrase,
                                configPassphrase: config.passphrase) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: "/docker stop \(container) [redacted]",
                       action: "docker_stop", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    case .restart(let appName, let passphrase):
        systemAction.restart(appName: appName, passphrase: passphrase,
                             configPassphrase: config.passphrase) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: "/restart \(appName) [redacted]",
                       action: "restart", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    // MARK: Scheduler
    case .snooze(let duration):
        proactiveMonitor.snooze(duration: duration)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "snooze", result: "ok", reply: "Snoozed")

    case .briefing:
        morningBriefing.send()
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "briefing", result: "ok", reply: "Briefing sent")

    // MARK: Misc
    case .log:
        let reply = log.formattedRecent()
        replyAction.send(reply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "log", result: "ok", reply: reply)

    case .help:
        replyAction.sendHelp()
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "help", result: "ok", reply: "Help sent")

    // MARK: Goals
    case .goalsStatus:
        guard let ga = goalAction else {
            replyAction.send("⚠️ Goal tracking is not enabled.")
            return
        }
        ga.handleStatus { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "goals_status", result: "ok", reply: reply)
        }

    case .goalsAdd(let text):
        guard let ga = goalAction else {
            replyAction.send("⚠️ Goal tracking is not enabled.")
            return
        }
        ga.handleAdd(rawText: text) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "goals_add", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    case .goalsRemove(let text):
        guard let ga = goalAction else {
            replyAction.send("⚠️ Goal tracking is not enabled.")
            return
        }
        ga.handleRemove(rawText: text) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "goals_remove", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    case .goalsLog(let text):
        guard let ga = goalAction else {
            replyAction.send("⚠️ Goal tracking is not enabled.")
            return
        }
        ga.handleSlashCheckin(rawText: text) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "goals_log", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    case .goalsHistory:
        guard let ga = goalAction else {
            replyAction.send("⚠️ Goal tracking is not enabled.")
            return
        }
        ga.handleHistory { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "goals_history", result: "ok", reply: reply)
        }

    // MARK: Location
    case .locationCurrent:
        guard let tracker = locationTracker else {
            replyAction.send("⚠️ Location tracking is not enabled.")
            return
        }
        tracker.scrapeNow { entry in
            if let e = entry {
                let label = e.label ?? e.address
                replyAction.send("📍 \(e.device): \(label)\n\(e.address)\n\(e.timestamp)")
            } else {
                replyAction.send("⚠️ Could not read location from database.")
            }
        }
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "location", result: "ok", reply: "Location sent")

    case .locationHistory:
        guard let tracker = locationTracker else {
            replyAction.send("⚠️ Location tracking is not enabled.")
            return
        }
        let summary = tracker.generateSummary()
        let reply = "📍 Today's Location History:\n\(summary)"
        replyAction.send(reply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "location_history", result: "ok", reply: reply)

    // MARK: FinForge
    case .financeBriefing:
        guard let ff = finforgeAction else {
            replyAction.send("⚠️ FinForge integration is not enabled.")
            return
        }
        ff.briefing { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_briefing", result: "ok", reply: reply)
        }

    case .financePortfolio:
        guard let ff = finforgeAction else {
            replyAction.send("⚠️ FinForge integration is not enabled.")
            return
        }
        ff.portfolio { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_portfolio", result: "ok", reply: reply)
        }

    case .financePredict(let symbol):
        guard let ff = finforgeAction else {
            replyAction.send("⚠️ FinForge integration is not enabled.")
            return
        }
        ff.predict(symbol: symbol) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_predict", result: "ok", reply: reply)
        }

    case .financeGoals:
        guard let ff = finforgeAction else {
            replyAction.send("⚠️ FinForge integration is not enabled.")
            return
        }
        ff.goals { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_goals", result: "ok", reply: reply)
        }

    case .financeWatchlist:
        guard let ff = finforgeAction else {
            replyAction.send("⚠️ FinForge integration is not enabled.")
            return
        }
        ff.watchlist { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_watchlist", result: "ok", reply: reply)
        }

    // MARK: Timezone
    case .setTimezone(let place):
        if place.isEmpty {
            replyAction.send("Current timezone: \(timezoneManager.displayName)")
            return
        }
        timezoneManager.resolve(placeName: place) { result in
            switch result {
            case .success(let tz):
                let reply = "Timezone set to \(tz.identifier). \(timezoneManager.displayName)"
                replyAction.send(reply)
                log.append(from: config.trustedSender, message: rawMessage,
                           action: "set_timezone", result: "ok", reply: reply)
            case .failure(let err):
                replyAction.send("Couldn't resolve '\(place)': \(err.localizedDescription)")
            }
        }

    // MARK: KPI
    case .kpiCommand(let subcommand, let args):
        guard let km = kpiManager else {
            replyAction.send("⚠️ KPI tracking is not enabled.")
            return
        }
        km.handleCommand(subcommand: subcommand, args: args, rawMessage: rawMessage) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "kpi_\(subcommand)", result: "ok", reply: reply)
        }

    // MARK: NLP Fallback
    case .nlpFallback(let text):
        nlpRouter.route(text) { result in
            dispatchNLP(result, rawMessage: rawMessage)
        }
    }
}

// MARK: - NLP Dispatcher

func dispatchNLP(_ result: NLPResult, rawMessage: String) {
    let config = configManager.current
    switch result.action {
    case "cal_add":
        let details = buildNLPCalDetails(result.params)
        dispatch(.calAdd(details), rawMessage: rawMessage)

    case "cal_parse":
        let text = result.params["text"] as? String ?? rawMessage
        dispatch(.calParse(text), rawMessage: rawMessage)

    case "remind_add":
        let details = buildNLPRemindDetails(result.params)
        dispatch(.remindAdd(details), rawMessage: rawMessage)

    case "remind_parse":
        let text = result.params["text"] as? String ?? rawMessage
        dispatch(.remindParse(text), rawMessage: rawMessage)

    case "status_all":
        dispatch(.statusAll, rawMessage: rawMessage)

    case "status_single":
        let name = result.params["app_name"] as? String ?? ""
        dispatch(.statusSingle(name), rawMessage: rawMessage)

    case "sys_health":
        dispatch(.sysHealth, rawMessage: rawMessage)

    case "docker_status":
        dispatch(.dockerStatus, rawMessage: rawMessage)

    case "docker_stop":
        let container = result.params["container_name"] as? String ?? ""
        let reply = "⚠️ Use /docker stop \(container) <passphrase> to stop this container."
        replyAction.send(reply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "nlp_docker_stop", result: "prompt", reply: reply)

    case "briefing":
        dispatch(.briefing, rawMessage: rawMessage)

    case "log":
        dispatch(.log, rawMessage: rawMessage)

    case "help":
        dispatch(.help, rawMessage: rawMessage)

    case "goal_checkin":
        guard let ga = goalAction else { break }
        let goalName = result.params["goal_name"] as? String ?? rawMessage
        let note = result.params["note"] as? String
        ga.handleCheckin(rawMessage: rawMessage, goalName: goalName, note: note) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "goal_checkin", result: reply.hasPrefix("✅") ? "success" : "error", reply: reply)
        }

    case "goal_add":
        guard let ga = goalAction else { break }
        let name = result.params["name"] as? String ?? ""
        let freq = result.params["frequency"] as? String ?? "daily"
        let reminderTime = result.params["reminder_time"] as? String
        let location = result.params["location"] as? String
        let addedGoal = ga.store.addGoal(name: name, frequency: freq, reminderTime: reminderTime, location: location)
        ga.reminder.reschedule()
        var reply = "✅ Goal added: \"\(addedGoal.name)\" (\(addedGoal.frequency))"
        if let t = addedGoal.reminderTime { reply += " — reminder at \(t)" }
        if let loc = addedGoal.location { reply += " — 📍 auto-check-in at \(loc)" }
        replyAction.send(reply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "goal_add", result: "success", reply: reply)

    case "finforge_briefing":
        guard let ff = finforgeAction else { break }
        ff.briefing { text in
            replyAction.send(text)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_briefing", result: "ok", reply: text)
        }

    case "finforge_portfolio":
        guard let ff = finforgeAction else { break }
        ff.portfolio { text in
            replyAction.send(text)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_portfolio", result: "ok", reply: text)
        }

    case "finforge_predict":
        guard let ff = finforgeAction else { break }
        let symbol = result.params["symbol"] as? String ?? "SPY"
        ff.predict(symbol: symbol) { text in
            replyAction.send(text)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_predict", result: "ok", reply: text)
        }

    case "finforge_goals":
        guard let ff = finforgeAction else { break }
        ff.goals { text in
            replyAction.send(text)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_goals", result: "ok", reply: text)
        }

    case "finforge_watchlist":
        guard let ff = finforgeAction else { break }
        ff.watchlist { text in
            replyAction.send(text)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_watchlist", result: "ok", reply: text)
        }

    case "finforge_chat":
        guard let ff = finforgeAction else { break }
        let msg = result.params["message"] as? String ?? rawMessage
        ff.chat(message: msg) { text in
            replyAction.send(text)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "finforge_chat", result: "ok", reply: text)
        }

    case "set_timezone":
        let place = result.params["place"] as? String ?? ""
        guard !place.isEmpty else { break }
        dispatch(.setTimezone(place), rawMessage: rawMessage)

    case "kpi_log":
        guard let km = kpiManager else {
            replyAction.send("⚠️ KPI tracking is not enabled.")
            break
        }
        // result.params is already the KPI fields dict
        var fields: [String: Any] = [:]
        let intKeys = ["life_sat", "energy_am", "lc_solved", "new_people", "meaningful_convos", "ideas_count"]
        let boolKeys = ["temple", "church"]
        for key in intKeys {
            if let v = result.params[key] {
                if let n = v as? Int { fields[key] = n }
                else if let s = v as? String, let n = Int(s) { fields[key] = n }
                else if let d = v as? Double { fields[key] = Int(d) }
            }
        }
        for key in boolKeys {
            if let v = result.params[key] {
                if let b = v as? Bool { fields[key] = b }
                else if let s = v as? String { fields[key] = (s == "true") }
            }
        }
        if let wt = result.params["workout_type"] as? String { fields["workout_type"] = wt }
        guard !fields.isEmpty else {
            replyAction.send("Couldn't extract any KPI values from that. Try /kpi sat 9.")
            break
        }
        let kpiReply = "Logged: " + fields.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: ", ")
        km.ingestFields(fields)
        replyAction.send(kpiReply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "kpi_log", result: "ok", reply: kpiReply)

    case "kpi_note":
        guard let km = kpiManager else {
            replyAction.send("⚠️ KPI tracking is not enabled.")
            break
        }
        let noteText = result.params["text"] as? String ?? rawMessage
        km.handleCommand(subcommand: "note", args: [noteText], rawMessage: rawMessage) { reply in
            replyAction.send(reply)
            log.append(from: config.trustedSender, message: rawMessage,
                       action: "kpi_note", result: "ok", reply: reply)
        }

    case "error":
        let reason = result.params["reason"] as? String ?? "Unknown error"
        let reply = "⚠️ NLP error: \(reason)"
        replyAction.send(reply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "nlp_error", result: "error", reply: reply)

    default:
        let reason = result.params["reason"] as? String ?? "Could not understand message"
        let reply  = "🤔 \(reason). Try /help for available commands."
        replyAction.send(reply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "nlp_unknown", result: "unknown", reply: reply)
    }
}

// MARK: - NLP param builders

func buildNLPCalDetails(_ params: [String: Any]) -> String {
    let title    = params["title"] as? String ?? ""
    let date     = params["date"] as? String ?? ""
    let dur      = params["duration_minutes"].flatMap { "\($0) minutes" } ?? ""
    let location = params["location"] as? String ?? ""
    var parts    = [title, date, dur, location].filter { !$0.isEmpty }
    if let notes = params["notes"] as? String, !notes.isEmpty { parts.append("notes: \(notes)") }
    return parts.joined(separator: ", ")
}

func buildNLPRemindDetails(_ params: [String: Any]) -> String {
    let title   = params["title"] as? String ?? ""
    let dueDate = params["due_date"] as? String ?? ""
    let list    = params["list"] as? String ?? ""
    return [title, dueDate, list].filter { !$0.isEmpty }.joined(separator: " ")
}

// MARK: - Startup

var watcher: MessageWatcher?

requestEventKitAccess { granted in
    if !granted {
        print("[NateBot] WARNING: EventKit access denied. Calendar/Reminder features will fail.")
        let warning = "⚠️ EventKit access not granted. Calendar and Reminder features are disabled. Check System Settings → Privacy."
        replyAction.send(warning)
    }

    // Start message watcher
    let w = MessageWatcher(trustedSender: configManager.current.trustedSender) { rawMessage in
        // KPI check-in state machine intercepts replies before normal routing
        if let km = kpiManager, km.handlePendingResponse(rawMessage) {
            return
        }
        let command = commandRouter.route(rawMessage)
        dispatch(command, rawMessage: rawMessage)
    }
    watcher = w
    w.start()

    // Wire FinForge to monitors and briefing
    proactiveMonitor.finforgeAction = finforgeAction
    morningBriefing.finforgeAction = finforgeAction

    // Wire KPI manager
    morningBriefing.kpiManager = kpiManager
    goalAction?.kpiManager = kpiManager

    // Wire timezone manager to all scheduling and formatting components
    morningBriefing.timezoneManager = timezoneManager
    goalReminder?.timezoneManager = timezoneManager
    goalAction?.timezoneManager = timezoneManager
    kpiManager?.timezoneManager = timezoneManager
    calendarAction.timezoneManager = timezoneManager
    reminderAction.timezoneManager = timezoneManager

    // Start proactive monitors
    proactiveMonitor.start()

    // Schedule morning briefing
    morningBriefing.scheduleDailyBriefing()

    // Schedule goal reminders
    goalReminder?.scheduleAllReminders()

    // Start location tracking
    locationTracker?.startTracking()

    // Schedule evening briefing (if configured)
    morningBriefing.scheduleEveningBriefing()

    // Schedule KPI nightly check-in (10 PM) and streak alerts (9 PM)
    kpiManager?.scheduleNightlyCheckin()
    kpiManager?.scheduleStreakAlerts()

    // Start web UI
    // Wire location tracker to goals for auto-check-in
    locationTracker?.goalStore = sharedGoalStore
    locationTracker?.reply = replyAction

    // Wire location tracker to goal reminders for location context
    goalReminder?.locationTracker = locationTracker

    // Pass location tracker to morning briefing for evening summaries
    morningBriefing.locationTracker = locationTracker

    let webRouter = WebRouter(
        configManager: configManager,
        log: log,
        goalStore: sharedGoalStore,
        locationTracker: locationTracker,
        calendarAction: calendarAction,
        reminderAction: reminderAction,
        statusAction: statusAction,
        systemAction: systemAction
    )
    let webServer = WebServer(router: webRouter)
    webServer.start(host: configManager.current.webUIHost, port: configManager.current.webUIPort)

    // Send startup message
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
    let startupMsg = "🤖 NateBot is online. \(ts) — \(configManager.current.apps.count) app\(configManager.current.apps.count == 1 ? "" : "s") registered, monitors active."
    replyAction.send(startupMsg)
    log.append(from: "system", message: "startup", action: "startup", result: "ok", reply: startupMsg)

    print("[NateBot] Online. Listening for messages from \(configManager.current.trustedSender)")
}

// Keep daemon alive
RunLoop.main.run()
