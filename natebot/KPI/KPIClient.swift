import Foundation

// MARK: - KPI Health Ingest Client
// Thin HTTP wrapper around POST /api/health-ingest.
// Also provides a psql helper for read queries (Parts 5 & 6).

class KPIClient {
    private let apiURL: URL
    private let apiKey: String

    init(apiURL: String, apiKey: String) {
        self.apiURL = URL(string: apiURL)!
        self.apiKey = apiKey
    }

    // MARK: - Ingest (POST)

    /// POST arbitrary JSON fields to the health-ingest endpoint (upsert by date).
    func ingest(_ fields: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else {
            print("[KPIClient] Could not serialize fields: \(fields)")
            completion?(false)
            return
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = data
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = status == 200
            if !ok {
                let desc = error?.localizedDescription ?? "HTTP \(status)"
                print("[KPIClient] Ingest failed: \(desc) — fields: \(fields.keys.joined(separator: ","))")
            } else {
                print("[KPIClient] Ingested: \(fields.keys.joined(separator: ","))")
            }
            completion?(ok)
        }.resume()
    }

    // MARK: - Query (psql)

    /// Run a SQL query against the KPI Postgres DB via psql.
    /// Returns stdout on success, nil on failure.
    func queryDB(sql: String, dbURL: String) -> String? {
        let args = [dbURL, "--no-align", "--tuples-only", "--csv", "-c", sql]

        // Try common psql paths (Homebrew ARM first on M-series)
        let candidates = [
            "/opt/homebrew/bin/psql",
            "/usr/local/bin/psql",
            "/usr/bin/psql",
        ]
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let result = runProcess(path, args: args)
            if result.exitCode == 0 {
                return result.stdout.isEmpty ? nil : result.stdout
            }
            print("[KPIClient] psql error at \(path): \(result.stderr.prefix(200))")
        }
        print("[KPIClient] psql not found at any known path.")
        return nil
    }

    // MARK: - Process runner

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(_ path: String, args: [String]) -> ProcessResult {
        let process = Process()
        process.launchPath = path
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
