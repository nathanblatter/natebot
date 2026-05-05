import Foundation
import Darwin

// MARK: - SystemAction

class SystemAction {
    let config: Config
    let reply: ReplyAction

    init(config: Config, reply: ReplyAction) {
        self.config = config
        self.reply = reply
    }

    // MARK: - /sys

    func systemHealth(completion: @escaping (String) -> Void) {
        let cpu          = Self.getCPUUsage()
        let (ramUsed, ramTotal) = Self.getRAMUsage()
        let (diskUsed, diskTotal) = Self.getDiskUsage()

        let cpuStr  = String(format: "%.0f%%", cpu)
        let ramStr  = String(format: "%.1f/%.0fGB", ramUsed, ramTotal)
        let diskStr = String(format: "%.0f/%.0fGB", diskUsed, diskTotal)

        completion("💻 CPU: \(cpuStr) · RAM: \(ramStr) · Disk: \(diskStr)")
    }

    // MARK: - /docker

    func dockerStatus(completion: @escaping (String) -> Void) {
        Self.getDockerStatuses { containers in
            if containers.isEmpty {
                completion("🐳 No Docker containers found (or Docker not running).")
                return
            }
            let lines = containers.map { c -> String in
                let emoji = c.isRunning ? "🟢" : "🔴"
                return "\(emoji) \(c.name) — \(c.status)"
            }
            completion("🐳 Docker:\n" + lines.joined(separator: "\n"))
        }
    }

    // MARK: - /restart

    func restart(appName: String, passphrase: String, configPassphrase: String, completion: @escaping (String) -> Void) {
        guard passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
                == configPassphrase.trimmingCharacters(in: .whitespacesAndNewlines) else {
            completion("⛔ Incorrect passphrase.")
            return
        }
        guard let app = config.apps.first(where: { $0.name.lowercased() == appName }) else {
            let available = config.apps.map { $0.name }.joined(separator: ", ")
            completion("⚠️ Unknown app '\(appName)'. Available: \(available)")
            return
        }

        completion("🔄 Restarting \(app.displayName)...")

        DispatchQueue.global(qos: .utility).async {
            let result = Self.runProcess("/usr/local/bin/docker", args: ["restart", app.name])
            DispatchQueue.main.async {
                if result.exitCode == 0 {
                    completion("✅ \(app.displayName) restarted successfully.")
                } else {
                    let err = result.stderr.isEmpty ? "Exit code \(result.exitCode)" : result.stderr
                    completion("⚠️ Restart failed: \(err)")
                }
            }
        }
    }

    // MARK: - /docker stop

    func dockerStop(containerName: String, passphrase: String, configPassphrase: String, completion: @escaping (String) -> Void) {
        guard passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
                == configPassphrase.trimmingCharacters(in: .whitespacesAndNewlines) else {
            completion("⛔ Incorrect passphrase.")
            return
        }

        let dockerPaths = ["/usr/local/bin/docker", "/usr/bin/docker", "/opt/homebrew/bin/docker"]
        guard let dockerPath = dockerPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            completion("⚠️ Docker not found.")
            return
        }

        completion("🛑 Stopping \(containerName)...")

        DispatchQueue.global(qos: .utility).async {
            let result = Self.runProcess(dockerPath, args: ["stop", containerName])
            DispatchQueue.main.async {
                if result.exitCode == 0 {
                    completion("✅ \(containerName) stopped.")
                } else {
                    let err = result.stderr.isEmpty ? "Exit code \(result.exitCode)" : result.stderr
                    completion("⚠️ Stop failed: \(err)")
                }
            }
        }
    }

    // MARK: - CPU (Darwin host_processor_info)

    static func getCPUUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0.0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var totalUser:   Int64 = 0
        var totalSystem: Int64 = 0
        var totalIdle:   Int64 = 0
        var totalNice:   Int64 = 0

        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            totalUser   += Int64(info[base + Int(CPU_STATE_USER)])
            totalSystem += Int64(info[base + Int(CPU_STATE_SYSTEM)])
            totalIdle   += Int64(info[base + Int(CPU_STATE_IDLE)])
            totalNice   += Int64(info[base + Int(CPU_STATE_NICE)])
        }

        let total = totalUser + totalSystem + totalIdle + totalNice
        let used  = totalUser + totalSystem + totalNice
        return total > 0 ? Double(used) / Double(total) * 100.0 : 0.0
    }

    // MARK: - RAM (vm_statistics64)

    static func getRAMUsage() -> (used: Double, total: Double) {
        // Total physical memory via sysctl
        var memSize: UInt64 = 0
        var memSizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0)
        let totalGB = Double(memSize) / 1_073_741_824

        // Used = active + wired
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { buf in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, buf, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, totalGB) }

        let pageSize  = Double(vm_page_size)
        let active    = Double(vmStats.active_count) * pageSize
        let wired     = Double(vmStats.wire_count)   * pageSize
        let usedGB    = (active + wired) / 1_073_741_824
        return (usedGB, totalGB)
    }

    // MARK: - Disk (FileManager)

    static func getDiskUsage() -> (used: Double, total: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
            return (0, 0)
        }
        let totalBytes = (attrs[.systemSize] as? Int64) ?? 0
        let freeBytes  = (attrs[.systemFreeSize] as? Int64) ?? 0
        let totalGB    = Double(totalBytes) / 1_073_741_824
        let usedGB     = Double(totalBytes - freeBytes) / 1_073_741_824
        return (usedGB, totalGB)
    }

    // MARK: - Docker containers

    struct DockerContainer {
        let name: String
        let status: String
        var isRunning: Bool { status.lowercased().hasPrefix("up") }
    }

    static func getDockerStatuses(completion: @escaping ([DockerContainer]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            // Try both common Docker paths
            let dockerPaths = ["/usr/local/bin/docker", "/usr/bin/docker", "/opt/homebrew/bin/docker"]
            guard let dockerPath = dockerPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                completion([])
                return
            }

            // --format "{{.Names}}\t{{.Status}}" for reliable TSV parsing
            let result = runProcess(dockerPath, args: ["ps", "-a", "--format", "{{.Names}}\t{{.Status}}"])
            guard result.exitCode == 0 else {
                completion([])
                return
            }

            let containers: [DockerContainer] = result.stdout
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .compactMap { line -> DockerContainer? in
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count >= 2 else { return nil }
                    return DockerContainer(name: parts[0].trimmingCharacters(in: .whitespaces),
                                          status: parts[1].trimmingCharacters(in: .whitespaces))
                }
            completion(containers)
        }
    }

    // MARK: - Process runner

    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func runProcess(_ path: String, args: [String]) -> ProcessResult {
        let process = Process()
        process.launchPath = path
        process.arguments  = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus,
                             stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                             stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
