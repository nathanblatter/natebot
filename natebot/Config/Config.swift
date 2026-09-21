import Foundation

// MARK: - Top-Level Config

struct Config: Codable {
    let trustedSender: String
    let passphrase: String
    /// Auth token for POST /api/chat (Apple Shortcuts webhook). Optional —
    /// falls back to the passphrase when absent.
    let chatToken: String?
    let claudeApiKey: String
    let briefing: BriefingConfig
    let log: LogConfig
    let apps: [AppConfig]
    let monitors: [MonitorConfig]
    let calendars: CalendarConfig
    let reminderLists: ReminderListConfig
    let locationTracking: LocationConfig?
    let finforge: FinForgeConfig?
    let kpi: KPIConfig?
    let canvas: CanvasConfig?
    let webUIPort: Int
    let webUIHost: String

    enum CodingKeys: String, CodingKey {
        case trustedSender = "trusted_sender"
        case passphrase
        case chatToken = "chat_token"
        case claudeApiKey = "claude_api_key"
        case briefing, log, apps, monitors, calendars
        case reminderLists = "reminder_lists"
        case locationTracking = "location_tracking"
        case finforge, kpi, canvas
        case webUIPort = "webui_port"
        case webUIHost = "webui_host"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trustedSender = try c.decode(String.self, forKey: .trustedSender)
        passphrase    = try c.decode(String.self, forKey: .passphrase)
        chatToken     = try c.decodeIfPresent(String.self, forKey: .chatToken)
        claudeApiKey  = try c.decode(String.self, forKey: .claudeApiKey)
        briefing      = try c.decode(BriefingConfig.self, forKey: .briefing)
        log           = try c.decode(LogConfig.self, forKey: .log)
        apps          = try c.decode([AppConfig].self, forKey: .apps)
        monitors      = try c.decode([MonitorConfig].self, forKey: .monitors)
        calendars     = try c.decode(CalendarConfig.self, forKey: .calendars)
        reminderLists = try c.decode(ReminderListConfig.self, forKey: .reminderLists)
        locationTracking = try c.decodeIfPresent(LocationConfig.self, forKey: .locationTracking)
        finforge      = try c.decodeIfPresent(FinForgeConfig.self, forKey: .finforge)
        kpi           = try c.decodeIfPresent(KPIConfig.self, forKey: .kpi)
        canvas        = try c.decodeIfPresent(CanvasConfig.self, forKey: .canvas)
        webUIPort     = try c.decodeIfPresent(Int.self, forKey: .webUIPort) ?? 47382
        webUIHost     = try c.decodeIfPresent(String.self, forKey: .webUIHost) ?? "127.0.0.1"
    }
}

// MARK: - Sub-Configs

struct BriefingConfig: Codable {
    let time: String          // "07:00"
    let eveningTime: String?  // "21:00" — optional evening briefing
    let includeOverdue: Bool
    let upcomingDays: Int

    enum CodingKeys: String, CodingKey {
        case time
        case eveningTime = "evening_time"
        case includeOverdue = "include_overdue"
        case upcomingDays = "upcoming_days"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(String.self, forKey: .time)
        eveningTime = try c.decodeIfPresent(String.self, forKey: .eveningTime)
        includeOverdue = try c.decode(Bool.self, forKey: .includeOverdue)
        upcomingDays = try c.decode(Int.self, forKey: .upcomingDays)
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

struct FinForgeConfig: Codable {
    let enabled: Bool
    let apiUrl: String      // "http://localhost:8001/api/v1"
    let apiKey: String
    let pollIntervalSeconds: Int  // 60

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiUrl = "api_url"
        case apiKey = "api_key"
        case pollIntervalSeconds = "poll_interval_seconds"
    }
}

struct KPIConfig: Codable {
    let enabled: Bool
    let apiUrl: String   // "https://nathanblatter.com/api/health-ingest"
    let apiKey: String
    let dbUrl: String    // "postgresql://postgres:postgres@localhost:5432/kpi"

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiUrl = "api_url"
        case apiKey = "api_key"
        case dbUrl  = "db_url"
    }
}

struct CanvasConfig: Codable {
    let enabled: Bool
    let icsUrl: String          // Canvas user calendar feed (embeds a per-user token — keep out of the repo)
    let refreshMinutes: Int?    // default 30

    enum CodingKeys: String, CodingKey {
        case enabled
        case icsUrl = "ics_url"
        case refreshMinutes = "refresh_minutes"
    }
}

struct LocationConfig: Codable {
    let enabled: Bool
    let device: String                    // e.g. "iPhone"
    let namedLocations: [String: String]  // address substring → label

    enum CodingKeys: String, CodingKey {
        case enabled
        case device
        case namedLocations = "named_locations"
    }
}

// MARK: - Loader

enum ConfigError: Error {
    case notFound
    case invalid(String)
}

class ConfigLoader {
    static func load() throws -> Config {
        return try loadWithURL().0
    }

    static func loadWithURL() throws -> (Config, URL) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates: [String] = [
            Bundle.main.bundlePath + "/Resources/natebot.json",
            Bundle.main.bundlePath + "/natebot.json",
            "Resources/natebot.json",
            "natebot.json",
            "\(home)/.config/natebot/natebot.json",
            "\(home)/Library/Application Support/NateBot/natebot.json"
        ]

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url) {
                do {
                    let config = try JSONDecoder().decode(Config.self, from: data)
                    return (config, url)
                } catch let decErr as DecodingError {
                    switch decErr {
                    case .keyNotFound(let key, let ctx):
                        throw ConfigError.invalid("Missing key '\(key.stringValue)' in \(path) — \(ctx.debugDescription)")
                    case .valueNotFound(let type, let ctx):
                        throw ConfigError.invalid("Null value for required field (\(type)) in \(path) — \(ctx.debugDescription)")
                    case .typeMismatch(let type, let ctx):
                        throw ConfigError.invalid("Type mismatch (\(type)) in \(path) — \(ctx.debugDescription)")
                    case .dataCorrupted(let ctx):
                        throw ConfigError.invalid("Corrupt JSON in \(path) — \(ctx.debugDescription)")
                    @unknown default:
                        throw ConfigError.invalid("Unknown decode error in \(path): \(decErr)")
                    }
                } catch {
                    throw ConfigError.invalid("Parse error in \(path): \(error)")
                }
            }
        }
        throw ConfigError.notFound
    }
}
