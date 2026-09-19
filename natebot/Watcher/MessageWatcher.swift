import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro that doesn't bridge to Swift automatically.
// This tells SQLite to copy the string before bind returns (safe for Swift strings).
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - InboundAttachment

struct InboundAttachment {
    let path: String   // absolute path on disk
    let mime: String   // may be empty if chat.db has no mime_type
}

// MARK: - MessageWatcher
// Polls ~/Library/Messages/chat.db every 3 seconds for new messages
// from the trusted sender — text, voice messages, and image attachments.
// Read-only SQLite access.

class MessageWatcher {
    private let dbPath: String
    private let trustedSender: String
    private var lastRowID: Int64 = -1
    private let onMessage: (String, [InboundAttachment]) -> Void
    private var pollTimer: Timer?

    // Attachments can still be mid-download when we first see the message row.
    // If a file isn't on disk yet, hold the row (and everything after it, to
    // preserve order) and re-poll, up to this many attempts before giving up.
    private var deferredRowID: Int64 = -1
    private var deferredAttempts = 0
    private let maxDeferredAttempts = 20  // × 3s poll = ~1 minute

    init(trustedSender: String, onMessage: @escaping (String, [InboundAttachment]) -> Void) {
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

    private var loggedInitFailure = false

    private func initializeLastRowID() {
        guard let db = openDB() else {
            if !loggedInitFailure {
                print("[MessageWatcher] Cannot open chat.db yet — will keep retrying. If this persists, check Full Disk Access in System Settings.")
                loggedInitFailure = true
            }
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
        // If startup init failed (chat.db not yet readable — e.g. launchd started
        // us before Full Disk Access / the disk was ready after a reboot), retry
        // initialization instead of polling: polling with lastRowID = -1 would
        // replay and reply to the entire message history.
        if lastRowID < 0 {
            initializeLastRowID()
            return
        }
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        // Join message + handle to get sender's Apple ID / phone number.
        // Pick up messages with text OR attachments (voice memos and images
        // usually have NULL text).
        let query = """
            SELECT m.ROWID, m.text, h.id
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ?
              AND m.is_from_me = 0
              AND LOWER(h.id) = LOWER(?)
              AND (
                (m.text IS NOT NULL AND LENGTH(TRIM(m.text)) > 0)
                OR EXISTS (SELECT 1 FROM message_attachment_join maj
                           WHERE maj.message_id = m.ROWID)
              )
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
            let text = (textPtr.flatMap { String(cString: $0) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let (attachments, allOnDisk) = fetchAttachments(db: db, messageID: rowID)

            // Attachment still downloading: hold this row (and later ones) and
            // retry next poll, unless we've waited long enough.
            if !allOnDisk {
                if rowID != deferredRowID {
                    deferredRowID = rowID
                    deferredAttempts = 0
                }
                deferredAttempts += 1
                if deferredAttempts <= maxDeferredAttempts {
                    return
                }
                print("[MessageWatcher] Giving up waiting for attachments on ROWID \(rowID)")
            }

            lastRowID = rowID

            guard !text.isEmpty || !attachments.isEmpty else { continue }

            print("[MessageWatcher] New message (ROWID \(rowID)): \(text.prefix(80)) [\(attachments.count) attachment(s)]")
            DispatchQueue.main.async { [weak self] in
                self?.onMessage(text, attachments)
            }
        }
    }

    /// Returns the message's attachments that exist on disk, plus whether every
    /// expected attachment has finished downloading.
    private func fetchAttachments(db: OpaquePointer, messageID: Int64) -> ([InboundAttachment], Bool) {
        let query = """
            SELECT a.filename, COALESCE(a.mime_type, '')
            FROM message_attachment_join maj
            JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE maj.message_id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return ([], true) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, messageID)

        var results: [InboundAttachment] = []
        var allOnDisk = true
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let fnPtr = sqlite3_column_text(stmt, 0) else {
                allOnDisk = false   // row exists but file path not recorded yet
                continue
            }
            var path = String(cString: fnPtr)
            if path.hasPrefix("~/") {
                path = home + path.dropFirst(1)
            }
            let mimePtr = sqlite3_column_text(stmt, 1)
            let mime = mimePtr.flatMap { String(cString: $0) } ?? ""

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                results.append(InboundAttachment(path: path, mime: mime))
            } else {
                allOnDisk = false
            }
        }
        return (results, allOnDisk)
    }
}
