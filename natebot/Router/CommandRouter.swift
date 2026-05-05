import Foundation

// MARK: - Parsed Command

enum ParsedCommand {
    // Calendar
    case calAdd(String)
    case calParse(String)

    // Reminders
    case remindAdd(String)
    case remindParse(String)

    // Status
    case statusAll
    case statusSingle(String)

    // System
    case sysHealth
    case dockerStatus
    case dockerStop(container: String, passphrase: String)
    case restart(app: String, passphrase: String)

    // Scheduler
    case snooze(TimeInterval)
    case briefing

    // Misc
    case log
    case help

    // Goals
    case goalsStatus
    case goalsAdd(String)
    case goalsRemove(String)
    case goalsLog(String)
    case goalsHistory

    // Location
    case locationCurrent
    case locationHistory

    // FinForge
    case financeBriefing
    case financePortfolio
    case financePredict(String)
    case financeGoals
    case financeWatchlist

    // NLP fallback
    case nlpFallback(String)
}

// MARK: - CommandRouter

class CommandRouter {

    /// Route a raw message string to a ParsedCommand.
    func route(_ text: String) -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return .nlpFallback(trimmed)
        }
        return parseSlashCommand(trimmed)
    }

    // MARK: - Slash command parser

    private func parseSlashCommand(_ text: String) -> ParsedCommand {
        // Split on whitespace, remove empties
        let parts = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = parts.first?.lowercased() else { return .help }

        switch first {

        // MARK: /cal
        case "/cal":
            guard parts.count >= 2 else { return .help }
            let sub = parts[1].lowercased()
            let rest = parts.dropFirst(2).joined(separator: " ")

            switch sub {
            case "parse":
                return .calParse(rest)
            case "add":
                return .calAdd(rest)
            default:
                // Treat "/cal dentist friday 2pm" as cal add
                let details = parts.dropFirst(1).joined(separator: " ")
                return .calAdd(details)
            }

        // MARK: /remind
        case "/remind":
            guard parts.count >= 2 else { return .help }
            let sub = parts[1].lowercased()
            let rest = parts.dropFirst(2).joined(separator: " ")

            if sub == "parse" {
                return .remindParse(rest)
            } else {
                let details = parts.dropFirst(1).joined(separator: " ")
                return .remindAdd(details)
            }

        // MARK: /status
        case "/status":
            if parts.count >= 2 {
                return .statusSingle(parts[1].lowercased())
            }
            return .statusAll

        // MARK: /sys
        case "/sys":
            return .sysHealth

        // MARK: /docker
        case "/docker":
            if parts.count >= 2 && parts[1].lowercased() == "stop" {
                let container = parts.count >= 3 ? parts[2] : ""
                let pass      = parts.count >= 4 ? parts[3] : ""
                return .dockerStop(container: container, passphrase: pass)
            }
            return .dockerStatus

        // MARK: /restart
        case "/restart":
            let app  = parts.count >= 2 ? parts[1].lowercased() : ""
            let pass = parts.count >= 3 ? parts[2] : ""
            return .restart(app: app, passphrase: pass)

        // MARK: /snooze
        case "/snooze":
            let raw = parts.count >= 2 ? parts[1] : "1h"
            return .snooze(parseDuration(raw))

        // MARK: /briefing
        case "/briefing":
            return .briefing

        // MARK: /log
        case "/log":
            return .log

        // MARK: /goals
        case "/goals":
            guard parts.count >= 2 else { return .goalsStatus }
            let sub  = parts[1].lowercased()
            let rest = parts.dropFirst(2).joined(separator: " ")

            switch sub {
            case "add":
                return .goalsAdd(rest)
            case "remove", "delete", "rm":
                return .goalsRemove(rest)
            case "log", "done", "check":
                return .goalsLog(rest)
            case "history":
                return .goalsHistory
            default:
                return .goalsStatus
            }

        // MARK: /location
        case "/location":
            if parts.count >= 2 && parts[1].lowercased() == "history" {
                return .locationHistory
            }
            return .locationCurrent

        // MARK: /finance, /portfolio, /stocks, /predict, /fingoals, /watchlist
        case "/finance":
            return .financeBriefing

        case "/portfolio", "/stocks":
            return .financePortfolio

        case "/predict":
            let symbol = parts.count >= 2 ? parts[1].uppercased() : "SPY"
            return .financePredict(symbol)

        case "/fingoals":
            return .financeGoals

        case "/watchlist":
            return .financeWatchlist

        // MARK: /help
        case "/help":
            return .help

        default:
            return .help
        }
    }

    // MARK: - Duration parser

    /// Parse "30m", "1h", "2h", plain number (treated as minutes).
    private func parseDuration(_ s: String) -> TimeInterval {
        let lower = s.lowercased()
        if lower.hasSuffix("h"), let val = Double(lower.dropLast()) {
            return val * 3600
        }
        if lower.hasSuffix("m"), let val = Double(lower.dropLast()) {
            return val * 60
        }
        if let val = Double(lower) {
            return val * 60   // bare number → minutes
        }
        return 3600  // default 1 hour
    }
}
