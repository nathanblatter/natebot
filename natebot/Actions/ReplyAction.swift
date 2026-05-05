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
        /cal add [details] — Add an event
        /cal parse [text] — Bulk-add events from text

        ✅ REMINDERS
        /remind [details] — Add a reminder
        /remind parse [text] — Bulk-add from text

        📊 STATUS
        /status — All app health
        /status [app] — Single app + stats

        💻 SYSTEM
        /sys — CPU, RAM, Disk
        /docker — Docker containers
        /restart [app] [passphrase] — Restart container

        ⏰ SCHEDULER
        /snooze [30m|1h|2h] — Snooze proactive alerts
        /briefing — Morning briefing on demand

        🎯 GOAL TRACKING
        /goals — Today's status for all goals
        /goals add [description] — Add a new goal
        /goals add [description] location:[Place] — Auto-check-in at a location
        /goals remove [goal name] — Remove a goal
        /goals log [goal name] — Log a completion
        /goals history — This week's completion history
        Or just say "I went for a run" and I'll figure it out!

        📍 LOCATION
        /location — Current iPhone location
        /location history — Today's location summary

        📋 MISC
        /log — Last 10 activity entries
        /help — This message

        💬 Or just say what you need naturally!
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
