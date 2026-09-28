import Foundation
import PhotoEngineApple
import PhotoEngineCore
import PhotoEnginePersistence
import PhotoEngineWorkflow

actor SessionRegistry {
    private let catalog: PhotoCatalog
    private let runner: PhotoPipelineRunner
    private var cache: [String: CurationSession] = [:]
    private var order: [String] = []

    init(catalog: PhotoCatalog, runner: PhotoPipelineRunner) {
        self.catalog = catalog
        self.runner = runner
    }

    func session(id: String) throws -> CurationSession? {
        if let cached = cache[id] { return cached }
        guard let loaded = try load(id: id) else { return nil }
        store(loaded)
        return loaded
    }

    func forget(id: String) {
        cache[id] = nil
        order.removeAll { $0 == id }
    }

    func saveLook(_ settings: LookSettings, sessionID: String) throws -> LookSettings {
        guard var session = try session(id: sessionID) else {
            throw APIError.notFound("No session \(sessionID)")
        }
        session.lookSettings = settings
        let url = session.result.runDirectory.appendingPathComponent("look-settings.json")
        try APIJSON.data(settings).write(to: url, options: .atomic)
        store(session)
        return settings
    }

    func applyPatch(_ patch: PhotoPatch, sessionID: String, photoID: String, ifMatch: String?) throws -> PhotoDTO {
        guard var session = try session(id: sessionID) else {
            throw APIError.notFound("No session \(sessionID)")
        }
        guard let uuid = UUID(uuidString: photoID) else { throw APIError.notFound("No photo \(photoID)") }
        let id = PhotoID(uuid)
        guard let row = session.row(for: id) else { throw APIError.notFound("No photo \(photoID)") }
        let current = PhotoMapping.etag(row: row, mark: session.mark(for: id), recipe: session.customRecipes[id])
        guard let ifMatch, ifMatch == current else {
            throw APIError.precondition("If-Match does not match this photo.")
        }
        let sid = try SessionID(uuid: sessionID)
        var mark = session.mark(for: id)
        if let flag = patch.flag {
            guard let value = ReviewFlag(rawValue: flag) else { throw APIError.invalid("Unknown flag \(flag).") }
            mark.flag = value
        }
        if let stars = patch.stars {
            guard (0...5).contains(stars) else { throw APIError.invalid("Stars must be from 0 to 5.") }
            mark.stars = stars
        }
        if let color = patch.color {
            guard let value = ReviewColor(rawValue: color) else { throw APIError.invalid("Unknown color \(color).") }
            mark.color = value
        }
        if patch.flag != nil || patch.stars != nil || patch.color != nil {
            try catalog.saveReviewMark(mark)
            session.marks[id] = mark
        }
        if let bucketName = patch.bucket {
            guard let bucket = SelectionBucket(rawValue: bucketName) else { throw APIError.invalid("Unknown bucket \(bucketName).") }
            try apply(bucket: bucket, to: id, session: &session, sid: sid)
        }
        if patch.clearRecipe {
            try catalog.deleteCustomRecipe(photoID: id, sessionID: sid)
            session.customRecipes[id] = nil
        } else if let recipe = patch.recipe {
            try catalog.saveCustomRecipe(recipe, photoID: id, sessionID: sid)
            session.customRecipes[id] = recipe
        }
        store(session)
        guard let updated = session.row(for: id), let dto = PhotoMapping.photo(updated, session: session, sid: sessionID) else {
            throw APIError.notFound("No photo \(photoID)")
        }
        return dto
    }

    func resolve(sessionID: String, momentID: String, action: String, photoID: String?) throws -> ConfirmationsBody {
        guard var session = try session(id: sessionID) else {
            throw APIError.notFound("No session \(sessionID)")
        }
        let pending = PhotoMapping.pending(session).moments
        guard let moment = pending.first(where: { $0.id == momentID }) ?? session.confirmations.moments.first(where: { $0.id == momentID }) else {
            throw APIError.notFound("No confirmation \(momentID)")
        }
        let sid = try SessionID(uuid: sessionID)
        switch action {
        case "skip":
            session.skippedConfirmationIDs.insert(moment.id)
        case "accept", "use", "drop":
            let confirmationAction: ConfirmationAction
            if action == "accept" {
                confirmationAction = .accept
            } else if action == "drop" {
                confirmationAction = .drop
            } else {
                guard let photoID, let uuid = UUID(uuidString: photoID) else { throw APIError.invalid("use requires photoID.") }
                confirmationAction = .use(PhotoID(uuid))
            }
            let resolution = ConfirmationBuilder.resolution(for: moment, action: confirmationAction, rows: session.rows)
            if resolution.marks.isEmpty && resolution.overrides.isEmpty && action == "use" {
                throw APIError.invalid("That photo is not part of this confirmation.")
            }
            for change in resolution.marks {
                var mark = session.mark(for: change.photoID)
                mark.flag = change.flag
                try catalog.saveReviewMark(mark)
                session.marks[change.photoID] = mark
            }
            for change in resolution.overrides {
                try apply(bucket: change.bucket, to: change.photoID, session: &session, sid: sid)
            }
        default:
            throw APIError.invalid("Unknown confirmation action \(action).")
        }
        store(session)
        return confirmationBody(session)
    }

    func confirmationBody(_ session: CurationSession) -> ConfirmationsBody {
        let pending = PhotoMapping.pending(session)
        let moments = pending.moments.map { moment in
            ConfirmationDTO(
                id: moment.id,
                kind: moment.isChoice ? "choice" : "single",
                suggestedID: moment.suggestedID.description,
                candidateIDs: moment.candidateIDs.map(\.description),
                hiddenRunnerUpIDs: moment.hiddenRunnerUpIDs.map(\.description),
                explanation: ConfirmationBuilder.explanation(for: moment, analyzed: session.result.analyzed)
            )
        }
        return ConfirmationsBody(moments: moments, beyondCap: pending.beyondCap)
    }

    private func apply(bucket: SelectionBucket, to photoID: PhotoID, session: inout CurationSession, sid: SessionID) throws {
        try runner.setOverride(sessionID: sid, photoID: photoID, bucket: bucket, reason: "user chose \(bucket.rawValue)")
        let updated = PhotoSelectionEngine.applying(
            [SelectionOverride(photoID: photoID, bucket: bucket, reason: "user chose \(bucket.rawValue)")],
            to: session.result.shortlist
        )
        var exports = session.result.exports
        if !GeneratedArtifactCleanup.bucketsThatRetainExports.contains(bucket),
           session.result.exports.contains(where: { $0.photoID == photoID }) {
            exports = try runner.discardExport(photoID: photoID, from: session.result).exports
        }
        try ManifestStore.update(session.result.manifestURL, shortlist: updated, exports: exports)
        let keptLooks = session.lookSettings
        let skipped = session.skippedConfirmationIDs
        guard var reloaded = try load(id: sid.description) else {
            throw APIError.notFound("No session \(sid.description)")
        }
        reloaded.lookSettings = keptLooks
        reloaded.skippedConfirmationIDs = skipped
        session = reloaded
    }

    private func load(id: String) throws -> CurationSession? {
        let sid = try SessionID(uuid: id)
        guard let snapshot = try catalog.session(id: sid), let manifestPath = snapshot.manifestPath else { return nil }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let result = try ManifestStore.loadResult(manifestURL: manifestURL)
        let marks = try catalog.reviewMarks(for: result.analyzed.map(\.id))
        let recipes = try catalog.customRecipes(sessionID: sid)
        var settings = LookSettings(lookID: "builtin.natural", temperature: 0, autoStraighten: true, renderBase: .raw)
        let lookURL = result.runDirectory.appendingPathComponent("look-settings.json")
        if let data = try? Data(contentsOf: lookURL), let stored = try? APIJSON.decoder.decode(LookSettings.self, from: data) {
            settings = stored
        }
        return CurationSession(
            result: result,
            marks: Dictionary(uniqueKeysWithValues: marks.map { ($0.photoID, $0) }),
            customRecipes: recipes,
            lookSettings: settings
        )
    }

    private func store(_ session: CurationSession) {
        let id = session.result.sessionID.description
        if cache[id] == nil { order.append(id) }
        cache[id] = session
        while order.count > 4 {
            let removed = order.removeFirst()
            if removed != id { cache[removed] = nil }
        }
    }
}

private extension SessionID {
    init(uuid string: String) throws {
        guard let uuid = UUID(uuidString: string) else { throw APIError.notFound("No session \(string)") }
        self.init(uuid)
    }
}
