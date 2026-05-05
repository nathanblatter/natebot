import Foundation

// MARK: - ProactiveMonitor
// Runs background monitors for app health, Docker, and system resources.
// All alerts are sent via ReplyAction to the trusted sender.

class ProactiveMonitor {
    private let config: Config
    private let statusAction: StatusAction
    private let systemAction: SystemAction
    private let reply: ReplyAction
    private let log: ActivityLog
    var finforgeAction: FinForgeAction?

    // Snooze: suppress all proactive alerts until this time
    private(set) var snoozeUntil: Date = .distantPast

    // Alert state — prevents re-alerting on the same condition
    private var appAlerted:    [String: Bool] = [:]   // app.name -> alerted
    private var dockerAlerted: [String: Bool] = [:]   // container.name -> alerted
    private var diskAlerted    = false
    private var cpuAlerted     = false
    private var cpuHighStart:  Date? = nil

    private var timers: [Timer] = []
    private let runLoopQueue = DispatchQueue(label: "com.natebot.monitors")

    init(config: Config,
         statusAction: StatusAction,
         systemAction: SystemAction,
         reply: ReplyAction,
         log: ActivityLog)
    {
        self.config       = config
        self.statusAction = statusAction
        self.systemAction = systemAction
        self.reply        = reply
        self.log          = log
    }

    // MARK: - Start

    func start() {
        for monitorConfig in config.monitors {
            let interval = TimeInterval(monitorConfig.intervalSeconds)
            switch monitorConfig.type {
            case "app_health":
                schedule(interval: interval) { [weak self] in self?.runAppHealthCheck() }
            case "docker":
                schedule(interval: interval) { [weak self] in self?.runDockerCheck() }
            case "system":
                schedule(interval: interval) { [weak self] in self?.runSystemCheck(cfg: monitorConfig) }
            case "finforge_poll":
                schedule(interval: interval) { [weak self] in
                    self?.finforgeAction?.pollPending { }
                }
            default:
                print("[ProactiveMonitor] Unknown monitor type: \(monitorConfig.type)")
            }
        }
        print("[ProactiveMonitor] \(config.monitors.count) monitor(s) started.")
    }

    // MARK: - Snooze

    func snooze(duration: TimeInterval) {
        snoozeUntil = Date().addingTimeInterval(duration)
        let minutes = Int(duration / 60)
        let unit    = minutes == 1 ? "minute" : "minutes"
        reply.send("⏸ Proactive alerts snoozed for \(minutes) \(unit).")
        log.append(from: "system", message: "snooze \(minutes)m",
                   action: "snooze", result: "ok", reply: "Snoozed \(minutes)m")
    }

    var isSnoozed: Bool { Date() < snoozeUntil }

    // MARK: - App Health

    private func runAppHealthCheck() {
        guard !isSnoozed else { return }
        for app in config.apps {
            statusAction.checkHealth(app: app) { [weak self] isUp, _ in
                guard let self = self else { return }
                let wasAlerted = self.appAlerted[app.name] ?? false

                if !isUp && !wasAlerted {
                    self.appAlerted[app.name] = true
                    var msg = "⚠️ \(app.displayName) is down."
                    if let last = self.statusAction.lastHealthy[app.name] {
                        let mins = Int(-last.timeIntervalSinceNow / 60)
                        msg += " Last healthy: \(mins) min ago."
                    }
                    self.alert(msg, action: "app_down")
                } else if isUp && wasAlerted {
                    self.appAlerted[app.name] = false
                    self.alert("✅ \(app.displayName) is back online.", action: "app_recovered")
                }
            }
        }
    }

    // MARK: - Docker

    private func runDockerCheck() {
        guard !isSnoozed else { return }
        SystemAction.getDockerStatuses { [weak self] containers in
            guard let self = self else { return }
            for container in containers {
                let stopped    = !container.isRunning
                let wasAlerted = self.dockerAlerted[container.name] ?? false

                if stopped && !wasAlerted {
                    self.dockerAlerted[container.name] = true
                    let msg = "⚠️ Docker container '\(container.name)' stopped. Status: \(container.status)"
                    self.alert(msg, action: "docker_stopped")
                } else if !stopped && wasAlerted {
                    self.dockerAlerted[container.name] = false
                    let msg = "✅ Docker container '\(container.name)' is running again."
                    self.alert(msg, action: "docker_recovered")
                }
            }
        }
    }

    // MARK: - System

    private func runSystemCheck(cfg: MonitorConfig) {
        guard !isSnoozed else { return }

        let diskThreshold = Double(cfg.diskThresholdPercent ?? 90)
        let cpuThreshold  = Double(cfg.cpuThresholdPercent ?? 95)
        let sustainMins   = Double(cfg.cpuSustainedMinutes ?? 5)

        // Disk
        let (diskUsed, diskTotal) = SystemAction.getDiskUsage()
        if diskTotal > 0 {
            let pct = (diskUsed / diskTotal) * 100
            if pct >= diskThreshold && !diskAlerted {
                diskAlerted = true
                let msg = String(format: "⚠️ Disk usage critical: %.0f%% (%.0f/%.0f GB)",
                                 pct, diskUsed, diskTotal)
                alert(msg, action: "disk_critical")
            } else if pct < diskThreshold - 5 {
                diskAlerted = false
            }
        }

        // CPU
        let cpu = SystemAction.getCPUUsage()
        if cpu >= cpuThreshold {
            if cpuHighStart == nil { cpuHighStart = Date() }
            if let start = cpuHighStart,
               !cpuAlerted,
               -start.timeIntervalSinceNow >= sustainMins * 60 {
                cpuAlerted = true
                let msg = String(format: "⚠️ CPU sustained at %.0f%% for %.0f+ minutes.", cpu, sustainMins)
                alert(msg, action: "cpu_critical")
            }
        } else {
            cpuHighStart = nil
            if cpuAlerted { cpuAlerted = false }
        }
    }

    // MARK: - Helpers

    private func alert(_ message: String, action: String) {
        DispatchQueue.main.async {
            self.reply.send(message)
            self.log.append(from: "monitor", message: action,
                            action: action, result: "alert", reply: message)
        }
    }

    private func schedule(interval: TimeInterval, block: @escaping () -> Void) {
        runLoopQueue.async {
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                block()
            }
            RunLoop.current.add(timer, forMode: .common)
            RunLoop.current.run()
        }
    }
}
