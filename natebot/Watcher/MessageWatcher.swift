import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro that doesn't bridge to Swift automatically.
// This tells SQLite to copy the string before bind returns (safe for Swift strings).
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - MessageWatcher
// Polls ~/Library/Messages/chat.db every 3 seconds for new messages
// from the trusted sender. Read-only SQLite access.

class MessageWatcher {
    private let dbPath: String
    private let trustedSender: String
    private var lastRowID: Int64 = -1
    private let onMessage: (String) -> Void
    private var pollTimer: Timer?

    init(trustedSender: String, onMessage: @escaping (String) -> Void) {
        self.trustedSender = trustedSender
        self.onMessage = onMessage
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        self.dbPath = "\(home)/Library/Messages/chat.db"
        initializeLastRowID()
    }

    // MARK: - Start / Stop

    func start() {
        // Run polling on a dedicated background queue with its own run loop
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.current.add(self.pollTimer!, forMode: .common)
            RunLoop.current.run()
        }
        print("[MessageWatcher] Started — watching \(dbPath)")
    }

    // MARK: - Private

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            return nil
        }
        return db
    }

    private func initializeLastRowID() {
        guard let db = openDB() else {
            print("[MessageWatcher] Cannot open chat.db — check Full Disk Access in System Settings.")
            return
        }
        defer { sqlite3_close(db) }

        // Set lastRowID to current max so we don't replay old messages on startup
        let query = "SELECT COALESCE(MAX(ROWID), 0) FROM message WHERE is_from_me = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            lastRowID = sqlite3_column_int64(stmt, 0)
        }
        print("[MessageWatcher] Initialized at message ROWID \(lastRowID)")
    }

    private func poll() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        // Join message + handle to get sender's Apple ID / phone number.
        // Only fetch messages newer than lastRowID from our trusted sender.
        let query = """
            SELECT m.ROWID, m.text, h.id
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ?
              AND m.is_from_me = 0
              AND m.text IS NOT NULL
              AND LENGTH(TRIM(m.text)) > 0
              AND LOWER(h.id) = LOWER(?)
            ORDER BY m.ROWID ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, lastRowID)
        sqlite3_bind_text(stmt, 2, trustedSender, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let textPtr = sqlite3_column_text(stmt, 1)
            let text = textPtr.flatMap { String(cString: $0) } ?? ""

            lastRowID = rowID

            guard !text.isEmpty else { continue }

            let message = text
            print("[MessageWatcher] New message (ROWID \(rowID)): \(message.prefix(80))")
            DispatchQueue.main.async { [weak self] in
                self?.onMessage(message)
            }
        }
    }
}
