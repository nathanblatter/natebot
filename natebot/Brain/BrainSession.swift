import Foundation

// MARK: - BrainSession
// NateBot's reasoning engine: every inbound message is handed to a headless
// Claude Code session (`claude -p`) running in ~/natebot-brain. The session is
// the NLP layer — it has Bash, file access, and MCP tools, so there is no
// intent routing in the daemon at all. Conversation continuity via --resume;
// the current session id is persisted so it survives daemon restarts.

final class BrainSession {
    private let reply: ReplyAction
    private let log: ActivityLog

    // Serial queue: messages are processed strictly in order, one session turn
    // at a time. Messages arriving mid-task queue up behind it.
    private let queue = DispatchQueue(label: "natebot.brain", qos: .userInitiated)

    private let workspacePath: String
    private let statePath: String
    private var sessionID: String?
    private var lastUsed: Date?

    /// Sessions older than this start fresh — yesterday's context rarely helps
    /// and stale context makes replies worse and slower.
    private let sessionMaxAge: TimeInterval = 6 * 60 * 60
    /// Hard ceiling on one brain turn. Agentic tasks can legitimately run long.
    private let turnTimeout: TimeInterval = 30 * 60
    /// If a turn is still running after this long, text an interim ack.
    private let slowAckDelay: TimeInterval = 20

    private let claudeBinary = "/opt/homebrew/bin/claude"
    /// The daemon runs under launchd with no login keychain, so the spawned CLI
    /// authenticates with the API key from natebot.json instead of OAuth.
    private let apiKey: String

    init(apiKey: String, reply: ReplyAction, log: ActivityLog) {
        self.apiKey = apiKey
        self.reply = reply
        self.log = log
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        self.workspacePath = "\(home)/natebot-brain"
        self.statePath = "\(home)/.config/natebot/brain-state.json"
        try? FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)
        loadState()
    }

    // MARK: - Public

    func handle(_ message: String) {
        queue.async { self.run(message) }
    }

    // MARK: - Turn execution

    private func run(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "new session" || trimmed == "reset session" {
            sessionID = nil
            saveState()
            reply.send("🧠 Fresh session.")
            log.append(from: "brain", message: message, action: "brain_reset", result: "ok", reply: "Fresh session")
            return
        }

        if let last = lastUsed, Date().timeIntervalSince(last) > sessionMaxAge {
            sessionID = nil
        }

        let resuming = sessionID
        var turn = executeTurn(message: message, resume: resuming)

        // A dead/pruned session id (or an errored resume) shouldn't eat the
        // message — retry fresh once.
        if !turn.ok && resuming != nil {
            sessionID = nil
            turn = executeTurn(message: message, resume: nil)
        }

        guard turn.ok, let result = turn.result else {
            let detail = turn.detail.prefix(300)
            reply.send("⚠️ Brain error: \(detail)")
            log.append(from: "brain", message: message, action: "brain", result: "error", reply: String(detail))
            return
        }

        if let sid = turn.sessionID { sessionID = sid }
        lastUsed = Date()
        saveState()

        var text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "✅ Done." }
        if text.count > 4000 { text = String(text.prefix(4000)) + "\n…(truncated)" }
        reply.send(text)
        log.append(from: "brain", message: message, action: "brain", result: "ok", reply: text)
    }

    private struct TurnOutcome {
        let ok: Bool
        let result: String?
        let sessionID: String?
        let detail: String
    }

    /// One `claude -p` turn: invoke, then interpret the JSON envelope. The CLI
    /// exits 0 even for in-band failures ("Not logged in", resume misses), so
    /// `is_error` must be checked, not just the exit status.
    private func executeTurn(message: String, resume: String?) -> TurnOutcome {
        let (status, output) = invoke(message: message, resume: resume)
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TurnOutcome(ok: false, result: nil, sessionID: nil,
                               detail: status == 0 ? "unparseable output: \(output.prefix(200))" : "exit \(status): \(output.prefix(200))")
        }
        let result = obj["result"] as? String
        let isError = (obj["is_error"] as? Bool) ?? false
        if status != 0 || isError {
            return TurnOutcome(ok: false, result: nil, sessionID: nil,
                               detail: result ?? "exit \(status)")
        }
        return TurnOutcome(ok: true, result: result ?? "",
                           sessionID: obj["session_id"] as? String, detail: "")
    }

    /// Runs one `claude -p` turn synchronously. Returns (exit status, stdout;
    /// stderr appended on failure so error replies carry the real cause).
    private func invoke(message: String, resume: String?) -> (Int32, String) {
        var args = ["-p", message, "--output-format", "json", "--dangerously-skip-permissions"]
        if let sid = resume { args += ["--resume", sid] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudeBinary)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

        // launchd agents get a bare environment; claude needs a real PATH and HOME.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["ANTHROPIC_API_KEY"] = apiKey
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain pipes on background threads — waiting first deadlocks on large output.
        var outData = Data(), errData = Data()
        let drainGroup = DispatchGroup()

        do {
            try process.run()
        } catch {
            return (-1, "failed to launch claude: \(error.localizedDescription)")
        }

        drainGroup.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        let ack = DispatchWorkItem { [reply] in
            reply.send("⏳ On it — this one's taking a bit.")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + slowAckDelay, execute: ack)

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + turnTimeout) == .timedOut {
            process.terminate()
            ack.cancel()
            return (-2, "turn exceeded \(Int(turnTimeout / 60)) minute timeout and was killed")
        }
        ack.cancel()
        drainGroup.wait()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        let status = process.terminationStatus
        return (status, status == 0 ? out : out + "\n" + err)
    }

    // MARK: - State persistence

    private func loadState() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        sessionID = obj["session_id"] as? String
        if let ts = obj["last_used"] as? Double { lastUsed = Date(timeIntervalSince1970: ts) }
    }

    private func saveState() {
        var obj: [String: Any] = [:]
        if let sid = sessionID { obj["session_id"] = sid }
        if let last = lastUsed { obj["last_used"] = last.timeIntervalSince1970 }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            FileManager.default.createFile(atPath: statePath, contents: data)
        }
    }
}
