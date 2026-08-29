// NateBot — macOS iMessage Automation Daemon
// Runs as a launchd agent. Every inbound iMessage is handed to a headless
// Claude Code session (BrainSession) — there is no command routing in the
// daemon. The daemon's jobs: watch chat.db, host the capability REST API
// (EventKit calendar/reminders, status, location), run scheduled briefings
// and KPI check-ins, and relay replies.

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

// 4. Action handlers (back the REST API + scheduled briefings)
let calendarAction = CalendarAction(store: eventStore, config: configManager.current, claude: claude)
let reminderAction = ReminderAction(store: eventStore, config: configManager.current, claude: claude)
let statusAction   = StatusAction(apps: configManager.current.apps)
let systemAction   = SystemAction(config: configManager.current, reply: replyAction)

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

// 7. The brain — headless Claude Code session orchestrator
let brain = BrainSession(apiKey: configManager.current.claudeApiKey, reply: replyAction, log: log)

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

// MARK: - Startup

var watcher: MessageWatcher?

requestEventKitAccess { granted in
    if !granted {
        print("[NateBot] WARNING: EventKit access denied. Calendar/Reminder features will fail.")
        let warning = "⚠️ EventKit access not granted. Calendar and Reminder features are disabled. Check System Settings → Privacy."
        replyAction.send(warning)
    }

    // Start message watcher — KPI check-in state machine intercepts replies to
    // pending nightly check-ins; everything else goes straight to the brain.
    let w = MessageWatcher(trustedSender: configManager.current.trustedSender) { rawMessage, attachments in
        if attachments.isEmpty, let km = kpiManager, km.handlePendingResponse(rawMessage) {
            return
        }
        brain.handle(rawMessage, attachments: attachments)
    }
    watcher = w
    w.start()

    // Wire FinForge to monitors and briefing
    proactiveMonitor.finforgeAction = finforgeAction
    morningBriefing.finforgeAction = finforgeAction

    // Wire KPI manager
    morningBriefing.kpiManager = kpiManager

    // Wire timezone manager to all scheduling and formatting components
    morningBriefing.timezoneManager = timezoneManager
    kpiManager?.timezoneManager = timezoneManager
    calendarAction.timezoneManager = timezoneManager
    reminderAction.timezoneManager = timezoneManager

    // Start proactive monitors
    proactiveMonitor.start()

    // Schedule morning briefing
    morningBriefing.scheduleDailyBriefing()

    // Start location tracking
    locationTracker?.startTracking()

    // Schedule evening briefing (if configured)
    morningBriefing.scheduleEveningBriefing()

    // Schedule KPI nightly check-in (10 PM) and streak alerts (9 PM)
    kpiManager?.scheduleNightlyCheckin()
    kpiManager?.scheduleStreakAlerts()

    // Pass location tracker to morning briefing for evening summaries
    morningBriefing.locationTracker = locationTracker

    let webRouter = WebRouter(
        configManager: configManager,
        log: log,
        locationTracker: locationTracker,
        calendarAction: calendarAction,
        reminderAction: reminderAction,
        statusAction: statusAction,
        systemAction: systemAction,
        brain: brain
    )
    let webServer = WebServer(router: webRouter)
    webServer.start(host: configManager.current.webUIHost, port: configManager.current.webUIPort)

    // Send startup message
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
    let startupMsg = "🤖 NateBot is online. \(ts) — brain session mode, monitors active."
    replyAction.send(startupMsg)
    log.append(from: "system", message: "startup", action: "startup", result: "ok", reply: startupMsg)

    print("[NateBot] Online. Listening for messages from \(configManager.current.trustedSender)")
}

// Keep daemon alive
RunLoop.main.run()
