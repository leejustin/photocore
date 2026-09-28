import Foundation
import Hummingbird
import PhotoEngineApple
import PhotoEngineCore
import PhotoEnginePersistence
import PhotoEngineWorkflow

struct ServerEnvironment: Sendable {
    let configuration: ServerConfiguration
    let catalog: PhotoCatalog
    let registry: SessionRegistry
    let jobs: JobQueue
    let media: MediaCache
    let runner: PhotoPipelineRunner
    let cancel: CancelFlags
}

func registerSessionRoutes(_ router: Router<BasicRequestContext>, env: ServerEnvironment) {
    router.get("v2/sessions") { request, _ in
        let limit = min(200, max(1, queryInt(request, "limit", default: 50)))
        let before = queryValue(request, "cursor").flatMap { ISO8601DateFormatter().date(from: $0) }
        let snapshots = try env.catalog.listSessions(limit: limit + 1, before: before)
        let page = Array(snapshots.prefix(limit))
        var items: [SessionSummaryDTO] = []
        for snapshot in page {
            items.append(try await summary(snapshot, env: env))
        }
        let next = snapshots.count > limit ? ISO8601DateFormatter().string(from: page.last?.createdAt ?? Date()) : nil
        return try APIJSON.response(Page(items: items, nextCursor: next))
    }

    router.post("v2/sessions") { request, context in
        let body = try await request.decode(as: CreateSessionBody.self, context: context)
        guard env.configuration.security.sourceDirectory(at: body.sourcePath) != nil else {
            throw APIError.forbidden("sourcePath is outside the allowed roots.")
        }
        if body.target != nil && body.keepPercent != nil {
            throw APIError.invalid("Send target or keepPercent, not both.")
        }
        let profile = try profile(from: body)
        let source = env.configuration.security.sourceDirectory(at: body.sourcePath)!
        let output = env.configuration.security.outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let record = JobRecord(
            id: UUID().uuidString,
            kind: "curate",
            sessionID: nil,
            state: "queued",
            request: try APIJSON.data(body),
            createdAt: Date()
        )
        let runner = env.runner
        let jobs = env.jobs
        let cancel = env.cancel
        let stored = try await jobs.enqueue(record) {
            let result = try runner.run(
                folder: source,
                outputDirectory: output,
                profile: profile,
                progress: { update in
                    Task { await jobs.noteProgress(id: record.id, stage: update.stage.rawValue, completed: update.completed, total: update.total, message: update.message) }
                },
                shouldCancel: { cancel.contains(record.id) }
            )
            return try APIJSON.data(["sessionID": result.sessionID.description])
        }
        return try APIJSON.response(JobDTO(stored), status: .accepted)
    }

    router.get("v2/sessions/{sid}") { _, context in
        let sid = try context.parameters.require("sid")
        guard let snapshot = try env.catalog.session(id: try sessionID(sid)) else { throw APIError.notFound("No session \(sid)") }
        guard let session = try await env.registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
        let settings = try env.catalog.sessionSettings(id: try sessionID(sid))
        let summary = try await summary(snapshot, env: env)
        let detail = SessionDetailDTO(
            id: summary.id,
            sourceName: summary.sourceName,
            status: summary.status,
            createdAt: summary.createdAt,
            completedAt: summary.completedAt,
            counts: summary.counts,
            pendingConfirmations: summary.pendingConfirmations,
            coverThumbURL: summary.coverThumbURL,
            settings: SessionSettingsBody(
                occasion: settings?.mode.rawValue ?? snapshot.mode.rawValue,
                cull: settings?.aggressiveness.rawValue ?? "balanced",
                target: settings?.sizingMode == .percentage ? nil : settings?.targetCount,
                keepPercent: settings?.sizingMode == .percentage ? settings?.keepPercentage : nil,
                renderBase: settings?.renderBase.rawValue ?? session.lookSettings.renderBase.rawValue
            ),
            look: session.lookSettings,
            metrics: MetricsBody(
                totalSeconds: session.result.metrics.totalSeconds,
                analysisSeconds: session.result.metrics.analysisSeconds,
                discoverySeconds: session.result.metrics.discoverySeconds,
                groupingSeconds: session.result.metrics.groupingSeconds,
                selectionSeconds: session.result.metrics.selectionSeconds,
                exportSeconds: session.result.metrics.exportSeconds
            )
        )
        return try APIJSON.response(detail)
    }

    router.delete("v2/sessions/{sid}") { _, context in
        let sid = try context.parameters.require("sid")
        guard let snapshot = try env.catalog.session(id: try sessionID(sid)) else { throw APIError.notFound("No session \(sid)") }
        if let path = snapshot.runDirectory {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let marker = directory.appendingPathComponent(PhotoPipelineRunner.runMarkerFileName)
            if FileManager.default.fileExists(atPath: directory.path) {
                guard FileManager.default.fileExists(atPath: marker.path) else {
                    throw APIError.forbidden("Refusing to delete a folder Photocore did not create.")
                }
                try FileManager.default.removeItem(at: directory)
            }
        }
        try env.catalog.deleteSession(try sessionID(sid))
        await env.registry.forget(id: sid)
        return Response(status: .noContent)
    }

    router.get("v2/sessions/{sid}/groups") { _, context in
        let sid = try context.parameters.require("sid")
        guard let session = try await env.registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
        let groups = session.result.grouping.groups.map { group in
            let keeper = group.memberIDs.max { lhs, rhs in
                (session.row(for: lhs)?.score ?? 0) < (session.row(for: rhs)?.score ?? 0)
            } ?? group.memberIDs[0]
            return GroupDTO(id: group.id.uuidString, kind: group.kind.rawValue, memberIDs: group.memberIDs.map(\.description), keeperID: keeper.description)
        }
        return try APIJSON.response(groups)
    }

    router.get("v2/sessions/{sid}/confirmations") { _, context in
        let sid = try context.parameters.require("sid")
        guard let session = try await env.registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
        return try APIJSON.response(await env.registry.confirmationBody(session))
    }

    router.post("v2/sessions/{sid}/confirmations/{mid}/resolve") { request, context in
        let sid = try context.parameters.require("sid")
        let mid = try context.parameters.require("mid")
        let body = try await request.decode(as: ResolveBody.self, context: context)
        let updated = try await env.registry.resolve(sessionID: sid, momentID: mid, action: body.action, photoID: body.photoID)
        return try APIJSON.response(updated)
    }

    router.get("v2/sessions/{sid}/look") { _, context in
        let sid = try context.parameters.require("sid")
        guard let session = try await env.registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
        return try APIJSON.response(session.lookSettings)
    }

    router.put("v2/sessions/{sid}/look") { request, context in
        let sid = try context.parameters.require("sid")
        let settings = try await request.decode(as: LookSettings.self, context: context)
        let stored = try await env.registry.saveLook(settings, sessionID: sid)
        return try APIJSON.response(stored)
    }

    router.post("v2/sessions/{sid}/deliveries") { request, context in
        let sid = try context.parameters.require("sid")
        let body = try await request.decode(as: DeliverBody.self, context: context)
        guard try await env.registry.session(id: sid) != nil else { throw APIError.notFound("No session \(sid)") }
        let preset = ExportPreset(rawValue: body.exportPreset ?? "full") ?? ExportPreset.full
        if body.exportPreset != nil && body.exportPreset != "full" && body.exportPreset != "compact" {
            throw APIError.invalid("exportPreset must be full or compact.")
        }
        let record = JobRecord(id: UUID().uuidString, kind: "deliver", sessionID: sid, state: "queued", request: try APIJSON.data(body), createdAt: Date())
        let registry = env.registry
        let outputRoot = env.configuration.security.outputRoot
        let writeSidecars = body.writeSidecarsBesideOriginals ?? false
        let stored = try await env.jobs.enqueue(record) {
            guard let session = try await registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
            let destination = outputRoot.appendingPathComponent("deliveries", isDirectory: true).appendingPathComponent(record.id, isDirectory: true)
            let look = LookComposer.effective(
                look: AlbumLookLibrary.shared.allLooks().first { $0.id == session.lookSettings.lookID } ?? AlbumLook.builtins[0],
                settings: session.lookSettings
            )
            let jobs = session.deliverRows.enumerated().compactMap { index, row -> DeliveryJob? in
                guard let photo = session.result.analyzed.first(where: { $0.id == row.id }) else { return nil }
                return DeliveryJob(
                    photo: photo,
                    fileName: String(format: "%03d-%@.jpg", index + 1, row.sourceURL.deletingPathExtension().lastPathComponent),
                    mark: session.mark(for: row.id),
                    customRecipe: session.customRecipes[row.id],
                    reusableExport: nil
                )
            }
            let sidecars: [SidecarJob] = writeSidecars ? session.rows.map { row in
                SidecarJob(mark: session.mark(for: row.id), baseName: row.sourceURL.deletingPathExtension().lastPathComponent, folder: row.sourceURL.deletingLastPathComponent())
            } : []
            let entries = session.rows.map { row in
                let mark = session.mark(for: row.id)
                return PortableCullEntry(fileName: row.sourceURL.lastPathComponent, relativePath: row.relativePath, bucket: row.bucket.rawValue, flag: mark.flag.rawValue, stars: mark.stars, color: mark.color.rawValue, reasons: row.reasons)
            }
            let report = try DeliveryExecutor.run(jobs: jobs, sidecars: sidecars, entries: entries, destination: destination, look: look, specification: ExportSpecification(preset: preset))
            return try APIJSON.data(DeliverResult(folder: report.folder.path, photoCount: report.photoCount, sidecarsSkipped: report.sidecarsSkipped))
        }
        return try APIJSON.response(JobDTO(stored), status: .accepted)
    }

    router.get("v2/sessions/{sid}/deliveries/{jid}/files") { _, context in
        let sid = try context.parameters.require("sid")
        let jid = try context.parameters.require("jid")
        guard let job = try await env.jobs.job(id: jid), job.kind == "deliver", job.sessionID == sid else {
            throw APIError.notFound("No delivery \(jid)")
        }
        guard let data = job.result, let result = try? APIJSON.decoder.decode(DeliverResult.self, from: data) else {
            throw APIError.conflict("Delivery is not ready.")
        }
        let folder = URL(fileURLWithPath: result.folder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.lowercased().hasSuffix(".jpg") }.sorted() ?? []
        let files = names.map { DeliveredFileDTO(fileName: $0, url: "/v2/media/\(sid)/deliveries/\(jid)/\($0)") }
        return try APIJSON.response(files)
    }
}

private struct DeliverResult: Codable {
    var folder: String
    var photoCount: Int
    var sidecarsSkipped: Int
}

private func sessionID(_ string: String) throws -> SessionID {
    guard let uuid = UUID(uuidString: string) else { throw APIError.notFound("No session \(string)") }
    return SessionID(uuid)
}

private func profile(from body: CreateSessionBody) throws -> ScoringProfile {
    guard let mode = CurationMode(rawValue: body.occasion ?? "everyday") else {
        throw APIError.invalid("Unknown occasion.")
    }
    guard let cull = CullingAggressiveness(rawValue: body.cull ?? "balanced") else {
        throw APIError.invalid("Unknown cull.")
    }
    var profile = ScoringProfile.default(for: mode)
    profile.apply(aggressiveness: cull)
    if let target = body.target {
        guard target > 0 else { throw APIError.invalid("target must be positive.") }
        profile.sizingMode = .count
        profile.targetCount = target
    }
    if let percent = body.keepPercent {
        guard percent.isFinite, (1...100).contains(percent) else { throw APIError.invalid("keepPercent must be from 1 to 100.") }
        profile.sizingMode = .percentage
        profile.keepPercentage = percent
    }
    switch body.renderBase ?? "raw" {
    case "raw": profile.renderBase = .raw
    case "cameraJPEG": profile.renderBase = .cameraJPEG
    default: throw APIError.invalid("renderBase must be raw or cameraJPEG.")
    }
    return profile
}

private func summary(_ snapshot: PhotoCatalog.SessionSnapshot, env: ServerEnvironment) async throws -> SessionSummaryDTO {
    let status: String
    switch snapshot.status {
    case "complete": status = "complete"
    case "processing": status = "running"
    default: status = snapshot.status == "failed" ? "failed" : snapshot.status
    }
    var counts = CountsBody(total: 0, album: 0, alternates: 0, needsLook: 0, hidden: 0, unusable: 0)
    var pending = 0
    var cover: String?
    if let session = try await env.registry.session(id: snapshot.id.description) {
        counts = PhotoMapping.counts(session: session)
        pending = PhotoMapping.pending(session).moments.count
        if let first = PhotoMapping.filtered(session, set: "album").first ?? session.rows.first {
            cover = "/v2/media/\(snapshot.id.description)/\(first.id.description)/thumb"
        }
    }
    return SessionSummaryDTO(
        id: snapshot.id.description,
        sourceName: snapshot.sourceFolder.lastPathComponent,
        status: status,
        createdAt: snapshot.createdAt,
        completedAt: snapshot.completedAt,
        counts: counts,
        pendingConfirmations: pending,
        coverThumbURL: cover
    )
}
