// NateBot — macOS iMessage Automation Daemon
// Runs as a launchd agent; listens for iMessages and executes macOS actions
// via Claude API as the reasoning engine.

import Foundation
import EventKit

// MARK: - Boot

print("[NateBot] Starting up...")

// 1. Load config
let config: Config
do {
    config = try ConfigLoader.load()
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
let log        = ActivityLog(maxEntries: config.log.maxEntries)
let claude     = ClaudeAPI(apiKey: config.claudeApiKey)
let replyAction = ReplyAction(trustedSender: config.trustedSender, log: log)

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
let calendarAction = CalendarAction(store: eventStore, config: config, claude: claude)
let reminderAction = ReminderAction(store: eventStore, config: config, claude: claude)
let statusAction   = StatusAction(apps: config.apps)
let systemAction   = SystemAction(config: config, reply: replyAction)

// 5. Routers
let commandRouter  = CommandRouter()
let nlpRouter      = NLPRouter(claude: claude)

// 6. Proactive monitors + morning briefing
let proactiveMonitor = ProactiveMonitor(
    config: config,
    statusAction: statusAction,
    systemAction: systemAction,
    reply: replyAction,
    log: log
)
let morningBriefing = MorningBriefing(
    config: config,
    store: eventStore,
    reply: replyAction,
    log: log
)

// MARK: - Message Dispatcher

/// Dispatches a parsed command to the appropriate action handler.
func dispatch(_ command: ParsedCommand, rawMessage: String) {
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

    case .restart(let appName, let passphrase):
        systemAction.restart(appName: appName, passphrase: passphrase,
                             configPassphrase: config.passphrase) { reply in
            replyAction.send(reply)
            // Never log the passphrase
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

    // MARK: NLP Fallback
    case .nlpFallback(let text):
        nlpRouter.route(text) { result in
            dispatchNLP(result, rawMessage: rawMessage)
        }
    }
}

// MARK: - NLP Dispatcher

func dispatchNLP(_ result: NLPResult, rawMessage: String) {
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

    case "briefing":
        dispatch(.briefing, rawMessage: rawMessage)

    case "log":
        dispatch(.log, rawMessage: rawMessage)

    case "help":
        dispatch(.help, rawMessage: rawMessage)

    case "error":
        let reply = "⚠️ NLP routing failed. Try a /slash command instead. Type /help for options."
        replyAction.send(reply)
        log.append(from: config.trustedSender, message: rawMessage,
                   action: "nlp_error", result: "error", reply: reply)

    default: // "unknown" or anything else
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

requestEventKitAccess { granted in
    if !granted {
        print("[NateBot] WARNING: EventKit access denied. Calendar/Reminder features will fail.")
        let warning = "⚠️ EventKit access not granted. Calendar and Reminder features are disabled. Check System Settings → Privacy."
        replyAction.send(warning)
    }

    // Start message watcher
    let watcher = MessageWatcher(trustedSender: config.trustedSender) { rawMessage in
        let command = commandRouter.route(rawMessage)
        dispatch(command, rawMessage: rawMessage)
    }
    watcher.start()

    // Start proactive monitors
    proactiveMonitor.start()

    // Schedule morning briefing
    morningBriefing.scheduleDailyBriefing()

    // Send startup message
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
    let startupMsg = "🤖 NateBot is online. \(ts) — \(config.apps.count) app\(config.apps.count == 1 ? "" : "s") registered, monitors active."
    replyAction.send(startupMsg)
    log.append(from: "system", message: "startup", action: "startup", result: "ok", reply: startupMsg)

    print("[NateBot] Online. Listening for messages from \(config.trustedSender)")
}

// Keep daemon alive
RunLoop.main.run()
