import Foundation
import SQLite3

/// SQLite-backed store compatible with original NDM schema field names.
public final class DownloadStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.path = directory.appendingPathComponent("NeatDB.db")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try open()
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // App Support container for this host
        return base.appendingPathComponent("dev.ndm.open", isDirectory: true)
    }

    private func open() throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path.path, &db, flags, nil) != SQLITE_OK {
            throw StoreError.openFailed(path.path)
        }
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS downloads (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT,
            method TEXT,
            filename TEXT,
            ltype TEXT,
            filesize NUMERIC,
            category TEXT,
            status TEXT,
            bandwidthlimit NUMERIC,
            connections NUMERIC,
            lasttry NUMERIC,
            firsttry NUMERIC,
            useragent TEXT,
            resumable NUMERIC,
            pageurl TEXT,
            pagetitle TEXT,
            hittitle TEXT,
            mimetype TEXT,
            errortext TEXT,
            urla TEXT,
            postdata TEXT,
            folderpath TEXT
        );
        CREATE TABLE IF NOT EXISTS auths (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            target TEXT,
            protocol TEXT,
            user TEXT,
            pass TEXT
        );
        CREATE TABLE IF NOT EXISTS headers (
            id NUMERIC,
            header TEXT
        );
        """
        try exec(sql)
    }

    public func allDownloads() throws -> [DownloadTask] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT * FROM downloads ORDER BY id DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        var items: [DownloadTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(rowToTask(stmt))
        }
        for i in items.indices {
            items[i].headers = try headersUnlocked(for: items[i].id)
        }
        return items
    }

    public func insert(_ task: DownloadTask) throws -> DownloadTask {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT INTO downloads (
            url, method, filename, ltype, filesize, category, status,
            bandwidthlimit, connections, lasttry, firsttry, useragent,
            resumable, pageurl, pagetitle, hittitle, mimetype, errortext,
            urla, postdata, folderpath
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        bind(task, to: stmt, includingID: false)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        var saved = task
        saved.id = sqlite3_last_insert_rowid(db)
        try replaceHeadersUnlocked(id: saved.id, headers: saved.headers)
        return saved
    }

    public func update(_ task: DownloadTask) throws {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        UPDATE downloads SET
            url=?, method=?, filename=?, ltype=?, filesize=?, category=?, status=?,
            bandwidthlimit=?, connections=?, lasttry=?, firsttry=?, useragent=?,
            resumable=?, pageurl=?, pagetitle=?, hittitle=?, mimetype=?, errortext=?,
            urla=?, postdata=?, folderpath=?
        WHERE id=?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        bind(task, to: stmt, includingID: false)
        sqlite3_bind_int64(stmt, 22, task.id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        try replaceHeadersUnlocked(id: task.id, headers: task.headers)
    }

    public func delete(id: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("DELETE FROM headers WHERE id=\(id);")
        try exec("DELETE FROM downloads WHERE id=\(id);")
    }

    // MARK: - Auths (original credentials table)

    public func allAuths() throws -> [AuthCredential] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT id, target, protocol, user, pass FROM auths ORDER BY id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        var items: [AuthCredential] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func t(_ i: Int32) -> String {
                guard let c = sqlite3_column_text(stmt, i) else { return "" }
                return String(cString: c)
            }
            items.append(AuthCredential(
                id: sqlite3_column_int64(stmt, 0),
                target: t(1),
                protocolName: t(2),
                username: t(3),
                password: t(4)
            ))
        }
        return items
    }

    public func insertAuth(_ auth: AuthCredential) throws -> AuthCredential {
        lock.lock()
        defer { lock.unlock() }
        let sql = "INSERT INTO auths (target, protocol, user, pass) VALUES (?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        func bind(_ i: Int32, _ s: String) {
            sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        bind(1, auth.target)
        bind(2, auth.protocolName)
        bind(3, auth.username)
        bind(4, auth.password)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        var saved = auth
        saved.id = sqlite3_last_insert_rowid(db)
        return saved
    }

    public func deleteAuth(id: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try exec("DELETE FROM auths WHERE id=\(id);")
    }

    /// Match by host/target substring (original looks up by download host).
    public func auth(forHost host: String) throws -> AuthCredential? {
        let all = try allAuths()
        let h = host.lowercased()
        return all.first { cred in
            let t = cred.target.lowercased()
            return t == h || h.contains(t) || t.contains(h)
        }
    }

    // MARK: - Private

    private func headersUnlocked(for id: Int64) throws -> [String] {
        let sql = "SELECT header FROM headers WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                result.append(String(cString: c))
            }
        }
        return result
    }

    private func replaceHeadersUnlocked(id: Int64, headers: [String]) throws {
        try exec("DELETE FROM headers WHERE id=\(id);")
        let sql = "INSERT INTO headers (id, header) VALUES (?, ?);"
        for header in headers {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.prepareFailed
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_bind_text(stmt, 2, header, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        }
    }

    private func bind(_ task: DownloadTask, to stmt: OpaquePointer?, includingID: Bool) {
        func text(_ i: Int32, _ s: String?) {
            if let s {
                sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, i)
            }
        }
        text(1, task.url)
        text(2, task.method)
        text(3, task.filename)
        text(4, task.linkType)
        sqlite3_bind_int64(stmt, 5, task.fileSize)
        text(6, task.category.rawValue)
        text(7, task.status.rawValue)
        sqlite3_bind_int64(stmt, 8, task.bandwidthLimit)
        sqlite3_bind_int(stmt, 9, Int32(task.connections))
        if let d = task.lastTry { sqlite3_bind_double(stmt, 10, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 10) }
        if let d = task.firstTry { sqlite3_bind_double(stmt, 11, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 11) }
        text(12, task.userAgent)
        sqlite3_bind_int(stmt, 13, task.resumable ? 1 : 0)
        text(14, task.pageURL)
        text(15, task.pageTitle)
        text(16, task.hitTitle)
        text(17, task.mimeType)
        text(18, task.errorText)
        text(19, task.alternateURL)
        if let data = task.postData, let s = String(data: data, encoding: .utf8) {
            text(20, s)
        } else {
            sqlite3_bind_null(stmt, 20)
        }
        text(21, task.folderPath)
        _ = includingID
    }

    private func rowToTask(_ stmt: OpaquePointer?) -> DownloadTask {
        func colText(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func colDate(_ i: Int32) -> Date? {
            if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
        }
        let category = DownloadCategory(rawValue: colText(6) ?? "misc") ?? .misc
        let status = DownloadStatus(rawValue: colText(7) ?? "incomplete") ?? .incomplete
        let post: Data? = colText(20).flatMap { $0.data(using: .utf8) }
        return DownloadTask(
            id: sqlite3_column_int64(stmt, 0),
            url: colText(1) ?? "",
            method: colText(2) ?? "GET",
            filename: colText(3) ?? "",
            linkType: colText(4) ?? "normal",
            fileSize: sqlite3_column_int64(stmt, 5),
            category: category,
            status: status,
            bandwidthLimit: sqlite3_column_int64(stmt, 8),
            connections: Int(sqlite3_column_int(stmt, 9)),
            lastTry: colDate(10),
            firstTry: colDate(11),
            userAgent: colText(12),
            resumable: sqlite3_column_int(stmt, 13) != 0,
            pageURL: colText(14),
            pageTitle: colText(15),
            hitTitle: colText(16),
            mimeType: colText(17),
            errorText: colText(18),
            alternateURL: colText(19),
            postData: post,
            folderPath: colText(21),
            headers: []
        )
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.execFailed(message)
        }
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed
    case stepFailed
    case execFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let p): return "Failed to open DB at \(p)"
        case .prepareFailed: return "Failed to prepare statement"
        case .stepFailed: return "Failed to step statement"
        case .execFailed(let m): return "SQL error: \(m)"
        }
    }
}
