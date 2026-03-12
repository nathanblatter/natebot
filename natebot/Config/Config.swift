import Foundation

// MARK: - Top-Level Config

struct Config: Codable {
    let trustedSender: String
    let passphrase: String
    let claudeApiKey: String
    let briefing: BriefingConfig
    let log: LogConfig
    let apps: [AppConfig]
    let monitors: [MonitorConfig]
    let calendars: CalendarConfig
    let reminderLists: ReminderListConfig

    enum CodingKeys: String, CodingKey {
        case trustedSender = "trusted_sender"
        case passphrase
        case claudeApiKey = "claude_api_key"
        case briefing, log, apps, monitors, calendars
        case reminderLists = "reminder_lists"
    }
}

// MARK: - Sub-Configs

struct BriefingConfig: Codable {
    let time: String          // "07:00"
    let includeOverdue: Bool
    let upcomingDays: Int

    enum CodingKeys: String, CodingKey {
        case time
        case includeOverdue = "include_overdue"
        case upcomingDays = "upcoming_days"
    }
}

struct LogConfig: Codable {
    let maxEntries: Int
    enum CodingKeys: String, CodingKey {
        case maxEntries = "max_entries"
    }
}

struct AppConfig: Codable {
    let name: String
    let displayName: String
    let healthURL: String
    let statsURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case healthURL = "health_url"
        case statsURL = "stats_url"
    }
}

struct MonitorConfig: Codable {
    let type: String
    let intervalSeconds: Int
    let diskThresholdPercent: Int?
    let cpuThresholdPercent: Int?
    let cpuSustainedMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case intervalSeconds = "interval_seconds"
        case diskThresholdPercent = "disk_threshold_percent"
        case cpuThresholdPercent = "cpu_threshold_percent"
        case cpuSustainedMinutes = "cpu_sustained_minutes"
    }
}

struct CalendarConfig: Codable {
    let defaultCalendar: String
    let work: String
    let school: String

    enum CodingKeys: String, CodingKey {
        case defaultCalendar = "default"
        case work, school
    }
}

struct ReminderListConfig: Codable {
    let defaultList: String
    let work: String
    let school: String

    enum CodingKeys: String, CodingKey {
        case defaultList = "default"
        case work, school
    }
}

// MARK: - Loader

enum ConfigError: Error {
    case notFound
    case invalid(String)
}

class ConfigLoader {
    static func load() throws -> Config {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates: [String] = [
            // Same directory as executable
            Bundle.main.bundlePath + "/Resources/natebot.json",
            Bundle.main.bundlePath + "/natebot.json",
            // Relative to working directory
            "Resources/natebot.json",
            "natebot.json",
            // ~/.config
            "\(home)/.config/natebot/natebot.json",
            // Application Support
            "\(home)/Library/Application Support/NateBot/natebot.json"
        ]

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url) {
                do {
                    return try JSONDecoder().decode(Config.self, from: data)
                } catch {
                    throw ConfigError.invalid("Parse error in \(path): \(error.localizedDescription)")
                }
            }
        }
        throw ConfigError.notFound
    }
}
