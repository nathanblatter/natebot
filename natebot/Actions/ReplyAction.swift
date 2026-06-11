import Foundation

// MARK: - ReplyAction
// Sends iMessages via osascript to the trusted sender.

class ReplyAction {
    let trustedSender: String
    private let log: ActivityLog

    init(trustedSender: String, log: ActivityLog) {
        self.trustedSender = trustedSender
        self.log = log
    }

    // MARK: - Send

    /// Send a message to the trusted sender. Retries once on failure.
    func send(_ message: String) {
        send(message, retries: 1)
    }

    private func send(_ message: String, retries: Int) {
        // Escape quotes for AppleScript string literal
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(trustedSender)" of targetService
            send "\(escaped)" to targetBuddy
        end tell
        """

        let success = runOsascript(script)

        if success {
            // Logged by caller for context; nothing extra needed here.
        } else if retries > 0 {
            Thread.sleep(forTimeInterval: 2.0)
            send(message, retries: retries - 1)
        } else {
            let err = "[ReplyAction] FAILED to deliver: \(message.prefix(80))"
            print(err)
            log.append(from: "system", message: message, action: "reply", result: "failed", reply: message)
        }
    }

    // MARK: - Help

    func sendHelp() {
        let help = """
        🤖 NateBot — Command Reference

        📅 CALENDAR
        /cal [details] — Add a calendar event
        /cal parse [text] — Bulk-add events from text

        ✅ REMINDERS
        /remind [details] — Add a reminder
        /remind parse [text] — Bulk-add from text

        🎯 GOAL TRACKING
        /goals — Today's status for all goals
        /goals add [description] — Add a new goal (include "at 8am" for reminders, "location:Gym" for auto-check-in)
        /goals remove [goal name] — Remove a goal
        /goals log [goal name] — Log a completion
        /goals history — This week's completion grid
        Or just say "I went for a run" and I'll figure it out!

        📈 KPI / HEALTH
        /kpi energy <1-10> — Morning energy
        /kpi sat <1-10> — Life satisfaction
        /kpi lc <n> — LeetCode problems solved
        /kpi met <n> — New people met
        /kpi ideas <n> — Ideas generated
        /kpi temple — Log temple attendance
        /kpi church — Log church attendance
        /kpi note <text> — Append a daily note
        /kpi status — Today's KPI snapshot
        /kpi week — Last 7 days summary
        /kpi query <question> — Ask anything about your data
        Or just say "I'm at a 9 for energy" and I'll log it!

        📍 LOCATION
        /location — Current location
        /location history — Today's location summary

        💻 SYSTEM
        /sys — CPU, RAM, Disk usage
        /docker — Docker container status
        /restart [app] [passphrase] — Restart a container

        📊 STATUS
        /status — All monitored app health
        /status [app] — Single app status

        ⏰ SCHEDULING
        /briefing — Morning briefing on demand
        /snooze [30m|1h|2h] — Snooze proactive alerts

        💰 FINANCE
        /finance — Daily finance briefing
        /portfolio — Portfolio snapshot
        /predict [SYMBOL] — Price prediction
        /fingoals — Financial goals
        /watchlist — Watchlist summary

        🌍 TIMEZONE
        /timezone [place] — Set your current timezone

        📋 MISC
        /log — Last 10 activity log entries
        /help — This message

        💬 Or just talk naturally — I'll figure it out!
        """
        send(help)
    }

    // MARK: - Private

    @discardableResult
    private func runOsascript(_ script: String) -> Bool {
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
