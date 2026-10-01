import Foundation
import Observation
import Photos
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow

/// One trip being culled on the phone. Photos are streamed from the library in
/// small batches and never copied; only the analysis is kept on disk.
@MainActor
@Observable
final class TripRun {
    enum Stage: Equatable {
        case idle
        case queued
        case analyzing(done: Int, total: Int)
        case paused(String)
        case deciding
        case ready
        case failed(String)
    }

    let trip: TripSummary
    private(set) var stage: Stage = .idle
    private(set) var outcome: StreamedCullResult?
    private(set) var moments: [ConfirmationMoment] = []
    private(set) var albumSaved = false
    private(set) var setAsideCount = 0
    private(set) var protectedCount = 0
    var selection = KeeperSelection(keepers: [])
    private var cancelWork: (() -> Void)?

    init(trip: TripSummary) {
        self.trip = trip
        setAsideCount = SetAsideLog.load().currentlySetAside(tripID: trip.id).count
    }

    var result: PipelineResult? { outcome?.result }

    var keepers: [AnalyzedPhoto] {
        guard let result else { return [] }
        return selection.ordered(in: result)
    }

    var openMoments: [ConfirmationMoment] {
        moments.filter { !selection.resolvedMoments.contains($0.id) }
    }

    var totalPhotos: Int { result?.analyzed.count ?? trip.photoCount }
    var skippedUtility: Int { outcome?.utilityCount ?? 0 }
    var isFinished: Bool { stage == .ready }

    /// Photos that were looked at and not kept, as Photos identifiers.
    var others: [String] {
        guard let result, let outcome else { return [] }
        return result.analyzed.map(\.id).filter { !selection.keepers.contains($0) }.compactMap { outcome.identifier(for: $0) }
    }

    func identifier(_ id: PhotoID) -> String? { outcome?.identifier(for: id) }

    func photo(_ id: PhotoID) -> AnalyzedPhoto? {
        result?.analyzed.first { $0.id == id }
    }

    func markQueued() {
        if stage == .idle { stage = .queued }
    }

    /// Runs the cull to completion. The queue calls this for one trip at a time.
    func perform() async {
        guard stage == .idle || stage == .queued else { return }
        stage = .analyzing(done: 0, total: trip.photoCount)
        let trip = trip
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            try await Self.cull(trip: trip) { event in
                Task { @MainActor in self?.apply(event) }
            }
        }
        cancelWork = { work.cancel() }
        defer { cancelWork = nil }
        do {
            let outcome = try await work.value
            self.outcome = outcome
            selection = KeeperSelection(result: outcome.result)
            moments = ConfirmationBuilder.build(
                result: outcome.result,
                rows: CuratedRow.rows(for: outcome.result),
                groups: PhotoGroupIndex.build(outcome.result.grouping)
            ).moments
            stage = .ready
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        cancelWork?()
    }

    private func apply(_ event: StreamedCullStage) {
        guard !isFinished else { return }
        switch event {
        case .analyzing(let done, let total): stage = .analyzing(done: done, total: total)
        case .paused(let reason): stage = .paused(reason)
        case .deciding: stage = .deciding
        }
    }

    func swipe(_ action: ConfirmationAction, on moment: ConfirmationMoment) {
        selection.apply(action, to: moment)
    }

    func toggle(_ id: PhotoID) {
        selection.toggle(id)
    }

    func saveAlbum() async throws {
        guard let outcome else { return }
        let identifiers = keepers.compactMap { outcome.identifier(for: $0.id) }
        try await PhotoLibraryWriter.saveAlbum(title: "Photocore · " + trip.title, localIdentifiers: identifiers, markFavorite: false)
        albumSaved = true
    }

    /// What setting aside would touch right now, after protection rules.
    func setAsidePlan() async -> SetAsidePlan {
        let candidates = others
        let keepIDs = Set(keepers.compactMap { identifier($0.id) })
        // Checking favorites, edits and albums touches Photos for every
        // candidate, so it runs off the main thread.
        let protection = await Task.detached(priority: .userInitiated) {
            PhotoLibrarySafety.protection(for: candidates)
        }.value
        return SetAsidePlanner.plan(candidates: candidates, keepers: keepIDs, protection: protection)
    }

    func setAside(_ plan: SetAsidePlan) async throws {
        try await PhotoLibrarySafety.setAside(plan.eligible, tripID: trip.id)
        setAsideCount = SetAsideLog.load().currentlySetAside(tripID: trip.id).count
        protectedCount = plan.protected.count
    }

    func restoreAll() async throws {
        var log = SetAsideLog.load()
        let identifiers = log.currentlySetAside(tripID: trip.id)
        try await PhotoLibrarySafety.restore(identifiers)
        log.record(identifiers, tripID: trip.id, state: .restored)
        try log.save()
        setAsideCount = 0
    }

    nonisolated private static func cull(
        trip: TripSummary,
        report: @escaping @Sendable (StreamedCullStage) -> Void
    ) async throws -> StreamedCullResult {
        let folder = try PhotoLibraryIngest.workingFolder(named: trip.id)
        let assets = PhotoLibraryIngest.fetchPhotos(from: trip.start.addingTimeInterval(-1), to: trip.end.addingTimeInterval(1))
        var profile = ScoringProfile.default(for: .trip)
        profile.sizingMode = .percentage
        profile.keepPercentage = 20
        return try await StreamedCuller().cull(
            source: PhotoKitTripSource(assets: assets),
            storeFolder: folder,
            profile: profile,
            progress: report
        )
    }
}

/// Runs trips one at a time. Starting several culls at once is what makes a
/// phone run hot and, in testing, what starves Vision of threads.
@MainActor
@Observable
final class TripQueue {
    private(set) var runs: [String: TripRun] = [:]
    private var waiting: [String] = []
    private(set) var activeID: String?

    func run(for trip: TripSummary) -> TripRun {
        if let existing = runs[trip.id] { return existing }
        let run = TripRun(trip: trip)
        runs[trip.id] = run
        return run
    }

    func enqueue(_ trip: TripSummary) {
        let run = run(for: trip)
        guard run.stage == .idle, !waiting.contains(trip.id), activeID != trip.id else { return }
        run.markQueued()
        waiting.append(trip.id)
        pump()
    }

    var activeTitle: String? { activeID.flatMap { runs[$0]?.trip.title } }

    private func pump() {
        guard activeID == nil, !waiting.isEmpty else { return }
        let id = waiting.removeFirst()
        guard let run = runs[id] else { return pump() }
        activeID = id
        Task {
            await run.perform()
            activeID = nil
            pump()
        }
    }

    /// Removes the full-size working copies older builds wrote. Only the small
    /// analysis store is kept now.
    static func removeLegacyWorkingCopies() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photocore/trips", isDirectory: true)
        guard let trips = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for trip in trips {
            for legacy in ["photos", "output"] {
                try? FileManager.default.removeItem(at: trip.appendingPathComponent(legacy, isDirectory: true))
            }
        }
    }
}
