import Foundation
import PhotoEngineCore
import SQLite3

/// A small SQLite catalog for durable sessions, decisions, and owned
/// artifacts. The fast analysis cache remains separate because it is
/// recreatable and can be evicted without affecting a user's session history.
public final class PhotoCatalog: @unchecked Sendable {
    public struct SessionSnapshot: Codable, Sendable, Equatable {
        public let id: SessionID
        public let sourceFolder: URL
        public let mode: CurationMode
        public let status: String
        public let createdAt: Date
        public let completedAt: Date?

        public init(id: SessionID, sourceFolder: URL, mode: CurationMode, status: String, createdAt: Date, completedAt: Date?) {
            self.id = id
            self.sourceFolder = sourceFolder
            self.mode = mode
            self.status = status
            self.createdAt = createdAt
            self.completedAt = completedAt
        }
    }

    public struct StorageSummary: Codable, Sendable, Equatable {
        public let sourceBytes: Int64
        public let generatedBytes: Int64
        public let cacheBytes: Int64

        public var totalBytes: Int64 { sourceBytes + generatedBytes + cacheBytes }

        public init(sourceBytes: Int64, generatedBytes: Int64, cacheBytes: Int64 = 0) {
            self.sourceBytes = sourceBytes
            self.generatedBytes = generatedBytes
            self.cacheBytes = cacheBytes
        }
    }

    public enum CatalogError: LocalizedError, Sendable {
        case openFailed(String)
        case statementFailed(String)
        case encodingFailed(String)

        public var errorDescription: String {
            switch self {
            case .openFailed(let message): "Could not open Photo Engine catalog: \(message)"
            case .statementFailed(let message): "Photo Engine catalog error: \(message)"
            case .encodingFailed(let message): "Could not encode catalog record: \(message)"
            }
        }
    }

    private let database: OpaquePointer
    private let encoder: JSONEncoder

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("PhotoEngine", isDirectory: true).appendingPathComponent("catalog.sqlite")
    }

    public init(url: URL = PhotoCatalog.defaultURL(), fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw CatalogError.openFailed(message)
        }
        database = handle
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try execute("PRAGMA foreign_keys = ON;")
        // journal_mode returns a row describing the selected mode, so use the
        // script API instead of the write-only statement helper.
        try executeScript("PRAGMA journal_mode = WAL;")
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    public func beginSession(id: SessionID, sourceFolder: URL, settings: ScoringProfile) throws {
        let settingsData = try encode(settings)
        try execute(
            """
            INSERT INTO sessions (id, source_folder, mode, settings, created_at, status)
            VALUES (?, ?, ?, ?, ?, 'processing')
            ON CONFLICT(id) DO UPDATE SET source_folder=excluded.source_folder,
                mode=excluded.mode, settings=excluded.settings, status='processing'
            """,
            bind: { statement in
                bindText(statement, 1, id.description)
                bindText(statement, 2, sourceFolder.standardizedFileURL.path)
                bindText(statement, 3, settings.mode.rawValue)
                bindBlob(statement, 4, settingsData)
                bindDouble(statement, 5, Date().timeIntervalSince1970)
            }
        )
    }

    public func upsert(asset: PhotoAsset, sessionID: SessionID, contentHash: String? = nil) throws {
        let metadata = try encode(asset.metadata)
        try execute(
            """
            INSERT INTO assets
                (id, session_id, source_path, relative_path, content_hash, source_signature,
                 file_size, modified_at, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id,
                source_path=excluded.source_path, relative_path=excluded.relative_path,
                content_hash=excluded.content_hash, source_signature=excluded.source_signature,
                file_size=excluded.file_size, modified_at=excluded.modified_at,
                metadata=excluded.metadata
            """,
            bind: { statement in
                bindText(statement, 1, asset.id.description)
                bindText(statement, 2, sessionID.description)
                bindText(statement, 3, asset.url.standardizedFileURL.path)
                bindText(statement, 4, asset.relativePath)
                bindText(statement, 5, contentHash ?? asset.contentHash ?? "")
                bindOptionalText(statement, 6, asset.sourceSignature)
                bindInt64(statement, 7, asset.metadata.fileSize)
                bindOptionalDouble(statement, 8, asset.sourceModifiedAt?.timeIntervalSince1970)
                bindBlob(statement, 9, metadata)
            }
        )
    }

    public func upsert(analysis: AnalysisSignals, for assetID: PhotoID, analyzerVersion: String) throws {
        let data = try encode(analysis)
        try execute(
            """
            INSERT INTO analyses (asset_id, analyzer_version, signals, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET analyzer_version=excluded.analyzer_version,
                signals=excluded.signals, updated_at=excluded.updated_at
            """,
            bind: { statement in
                bindText(statement, 1, assetID.description)
                bindText(statement, 2, analyzerVersion)
                bindBlob(statement, 3, data)
                bindDouble(statement, 4, Date().timeIntervalSince1970)
            }
        )
    }

    public func replaceDecisions(_ decisions: [SelectionDecision], sessionID: SessionID) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("DELETE FROM decisions WHERE session_id = ?", bind: { bindText($0, 1, sessionID.description) })
            for decision in decisions {
                let reasons = try encode(decision.reasons)
                try execute(
                    """
                    INSERT INTO decisions
                        (session_id, photo_id, bucket, rank, score, reasons, is_override)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    """,
                    bind: { statement in
                        bindText(statement, 1, sessionID.description)
                        bindText(statement, 2, decision.photoID.description)
                        bindText(statement, 3, decision.bucket.rawValue)
                        bindOptionalInt(statement, 4, decision.rank)
                        bindDouble(statement, 5, decision.score)
                        bindBlob(statement, 6, reasons)
                    }
                )
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func recordArtifact(sessionID: SessionID, photoID: PhotoID?, kind: String, url: URL, recipe: EditRecipe? = nil) throws {
        let recipeData = try recipe.map(encode)
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try execute(
            """
            INSERT INTO artifacts (session_id, photo_id, kind, path, bytes, recipe, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bind: { statement in
                bindText(statement, 1, sessionID.description)
                bindOptionalText(statement, 2, photoID?.description)
                bindText(statement, 3, kind)
                bindText(statement, 4, url.standardizedFileURL.path)
                bindInt64(statement, 5, byteCount)
                bindOptionalBlob(statement, 6, recipeData)
                bindDouble(statement, 7, Date().timeIntervalSince1970)
            }
        )
    }

    public func finishSession(_ id: SessionID, status: String = "complete") throws {
        try execute(
            "UPDATE sessions SET status = ?, completed_at = ? WHERE id = ?",
            bind: { statement in
                bindText(statement, 1, status)
                bindDouble(statement, 2, Date().timeIntervalSince1970)
                bindText(statement, 3, id.description)
            }
        )
    }

    public func storageSummary(sessionID: SessionID, cacheBytes: Int64 = 0) throws -> StorageSummary {
        let sourceBytes = try scalarInt64(
            "SELECT COALESCE(SUM(file_size), 0) FROM assets WHERE session_id = ?",
            bind: { bindText($0, 1, sessionID.description) }
        )
        let generatedBytes = try scalarInt64(
            "SELECT COALESCE(SUM(bytes), 0) FROM artifacts WHERE session_id = ?",
            bind: { bindText($0, 1, sessionID.description) }
        )
        return StorageSummary(sourceBytes: sourceBytes, generatedBytes: generatedBytes, cacheBytes: cacheBytes)
    }

    public func recordCleanupPlan(_ plan: CleanupPlan, status: String = "preview") throws {
        let targets = try encode(plan.candidates)
        try execute(
            """
            INSERT INTO cleanup_plans (id, session_id, status, targets, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, targets=excluded.targets
            """,
            bind: { statement in
                bindText(statement, 1, plan.id.uuidString)
                bindText(statement, 2, plan.sessionID.description)
                bindText(statement, 3, status)
                bindBlob(statement, 4, targets)
                bindDouble(statement, 5, plan.createdAt.timeIntervalSince1970)
            }
        )
    }

    public func updateCleanupPlanStatus(_ planID: UUID, status: String, approvedAt: Date? = nil, completedAt: Date? = nil) throws {
        try execute(
            """
            UPDATE cleanup_plans
            SET status = ?, approved_at = COALESCE(?, approved_at), completed_at = COALESCE(?, completed_at)
            WHERE id = ?
            """,
            bind: { statement in
                bindText(statement, 1, status)
                bindOptionalDouble(statement, 2, approvedAt?.timeIntervalSince1970)
                bindOptionalDouble(statement, 3, completedAt?.timeIntervalSince1970)
                bindText(statement, 4, planID.uuidString)
            }
        )
    }

    public func session(id: SessionID) throws -> SessionSnapshot? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT source_folder, mode, status, created_at, completed_at FROM sessions WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, id.description)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        guard let sourceCString = sqlite3_column_text(statement, 0),
              let modeCString = sqlite3_column_text(statement, 1),
              let statusCString = sqlite3_column_text(statement, 2),
              let mode = CurationMode(rawValue: String(cString: modeCString)) else {
            throw CatalogError.statementFailed("Stored session has invalid fields")
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let completedAt = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        return SessionSnapshot(
            id: id,
            sourceFolder: URL(fileURLWithPath: String(cString: sourceCString), isDirectory: true),
            mode: mode,
            status: String(cString: statusCString),
            createdAt: createdAt,
            completedAt: completedAt
        )
    }

    public func decisions(sessionID: SessionID) throws -> [SelectionDecision] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT photo_id, bucket, rank, score, reasons FROM decisions WHERE session_id = ? ORDER BY COALESCE(rank, 2147483647), photo_id",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, sessionID.description)
        var values: [SelectionDecision] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let photoCString = sqlite3_column_text(statement, 0),
                  let bucketCString = sqlite3_column_text(statement, 1),
                  let photoUUID = UUID(uuidString: String(cString: photoCString)),
                  let bucket = SelectionBucket(rawValue: String(cString: bucketCString)) else {
                throw CatalogError.statementFailed("Stored decision has invalid identity")
            }
            let reasonsData = blobData(statement, column: 4)
            let reasons = (try? JSONDecoder().decode([String].self, from: reasonsData)) ?? []
            let rank = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2))
            values.append(SelectionDecision(
                photoID: PhotoID(photoUUID),
                bucket: bucket,
                rank: rank,
                reasons: reasons,
                score: sqlite3_column_double(statement, 3)
            ))
        }
        return values
    }

    public func saveOverride(_ override: SelectionOverride) throws {
        try execute(
            """
            INSERT INTO overrides (photo_id, bucket, reason, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(photo_id) DO UPDATE SET bucket=excluded.bucket,
                reason=excluded.reason, updated_at=excluded.updated_at
            """,
            bind: { statement in
                bindText(statement, 1, override.photoID.description)
                bindText(statement, 2, override.bucket.rawValue)
                bindText(statement, 3, override.reason)
                bindDouble(statement, 4, Date().timeIntervalSince1970)
            }
        )
    }

    public func applyOverride(_ override: SelectionOverride, sessionID: SessionID) throws {
        let reasons = try encode([override.reason])
        try execute(
            """
            UPDATE decisions
            SET bucket = ?, rank = NULL, reasons = ?, is_override = 1
            WHERE session_id = ? AND photo_id = ?
            """,
            bind: { statement in
                bindText(statement, 1, override.bucket.rawValue)
                bindBlob(statement, 2, reasons)
                bindText(statement, 3, sessionID.description)
                bindText(statement, 4, override.photoID.description)
            }
        )
    }

    public func deleteOverride(photoID: PhotoID) throws {
        try execute(
            "DELETE FROM overrides WHERE photo_id = ?",
            bind: { bindText($0, 1, photoID.description) }
        )
    }

    public func overrides(for photoIDs: [PhotoID]) throws -> [SelectionOverride] {
        guard !photoIDs.isEmpty else { return [] }
        var values: [SelectionOverride] = []
        // SQLite's default host-parameter limit is commonly 999. Chunking
        // keeps a large shoot's re-curation path reliable without changing
        // the catalog schema or requiring a temporary table.
        for start in stride(from: 0, to: photoIDs.count, by: 900) {
            let end = min(start + 900, photoIDs.count)
            let chunk = Array(photoIDs[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var statement: OpaquePointer?
            let sql = "SELECT photo_id, bucket, reason FROM overrides WHERE photo_id IN (\(placeholders))"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            for (index, photoID) in chunk.enumerated() {
                bindText(statement, Int32(index + 1), photoID.description)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let photoCString = sqlite3_column_text(statement, 0),
                      let bucketCString = sqlite3_column_text(statement, 1),
                      let photoUUID = UUID(uuidString: String(cString: photoCString)),
                      let bucket = SelectionBucket(rawValue: String(cString: bucketCString)) else {
                    throw CatalogError.statementFailed("Stored override has invalid identity")
                }
                let reason = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "user override"
                values.append(SelectionOverride(photoID: PhotoID(photoUUID), bucket: bucket, reason: reason))
            }
        }
        return values
    }

    private func migrate() throws {
        let schemaVersion = try scalarInt64("PRAGMA user_version;")
        if schemaVersion < 1 {
            try executeScript(
                """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                source_folder TEXT NOT NULL,
                mode TEXT NOT NULL,
                settings BLOB NOT NULL,
                created_at REAL NOT NULL,
                completed_at REAL,
                status TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                source_path TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                source_signature TEXT,
                file_size INTEGER NOT NULL,
                modified_at REAL,
                metadata BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS assets_session_index ON assets(session_id);
            CREATE TABLE IF NOT EXISTS analyses (
                asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
                analyzer_version TEXT NOT NULL,
                signals BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS decisions (
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                photo_id TEXT NOT NULL,
                bucket TEXT NOT NULL,
                rank INTEGER,
                score REAL NOT NULL,
                reasons BLOB NOT NULL,
                is_override INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (session_id, photo_id)
            );
            CREATE TABLE IF NOT EXISTS artifacts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                photo_id TEXT,
                kind TEXT NOT NULL,
                path TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                recipe BLOB,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS artifacts_session_index ON artifacts(session_id);
            CREATE TABLE IF NOT EXISTS cleanup_plans (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                status TEXT NOT NULL,
                targets BLOB NOT NULL,
                created_at REAL NOT NULL,
                approved_at REAL,
                completed_at REAL
            );
            """
            )
            try executeScript("PRAGMA user_version = 1;")
        }
        if schemaVersion < 2 {
            try executeScript(
                """
                CREATE TABLE IF NOT EXISTS overrides (
                    photo_id TEXT PRIMARY KEY,
                    bucket TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """
            )
            try executeScript("PRAGMA user_version = 2;")
        }
    }

    private func executeScript(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(message) }
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let fallback = String(cString: sqlite3_errmsg(database))
            let detail = message.map { String(cString: $0) } ?? fallback
            throw CatalogError.statementFailed(detail)
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw CatalogError.encodingFailed(error.localizedDescription) }
    }

    private func execute(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func scalarInt64(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CatalogError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
}

private func bindOptionalText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    bindText(statement, index, value)
}

private func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) {
    sqlite3_bind_double(statement, index, value)
}

private func bindOptionalDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    bindDouble(statement, index, value)
}

private func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) {
    sqlite3_bind_int64(statement, index, value)
}

private func bindOptionalInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    sqlite3_bind_int(statement, index, Int32(value))
}

private func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
    _ = value.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), sqliteTransient)
    }
}

private func bindOptionalBlob(_ statement: OpaquePointer, _ index: Int32, _ value: Data?) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    bindBlob(statement, index, value)
}

private func blobData(_ statement: OpaquePointer, column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: pointer, count: count)
}
