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
