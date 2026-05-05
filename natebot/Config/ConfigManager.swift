import Foundation

// MARK: - ConfigManager
// Thread-safe wrapper around live Config. Saves atomically and updates in-memory.

class ConfigManager {
    private var _current: Config
    private let queue = DispatchQueue(label: "com.natebot.config", attributes: .concurrent)
    let configURL: URL

    init(config: Config, configURL: URL) {
        self._current = config
        self.configURL = configURL
    }

    var current: Config {
        queue.sync { _current }
    }

    func save(_ newConfig: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(newConfig)
        try data.write(to: configURL, options: .atomic)
        queue.async(flags: .barrier) { self._current = newConfig }
    }
}
