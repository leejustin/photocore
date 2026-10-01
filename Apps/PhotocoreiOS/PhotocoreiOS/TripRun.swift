import Foundation
import Observation
import Photos
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow

/// One trip being culled on the phone: read from Photos, culled by the engine,
/// then edited by swipes. Everything here runs on device.
@MainActor
@Observable
final class TripRun {
    enum Stage: Equatable {
        case idle
        case reading(done: Int, total: Int)
        case culling(done: Int, total: Int)
        case ready
        case saved(albumTitle: String)
        case failed(String)
    }

    let trip: TripSummary
    private(set) var stage: Stage = .idle
    private(set) var result: PipelineResult?
    private(set) var moments: [ConfirmationMoment] = []
    private(set) var skippedUtility = 0
    var selection = KeeperSelection(keepers: [])
    private var index = LibraryExportIndex()
    private var task: Task<Void, Never>?
    private let cancelFlag = CancelFlag()

    init(trip: TripSummary) {
        self.trip = trip
    }

    var keepers: [AnalyzedPhoto] {
        guard let result else { return [] }
        return selection.ordered(in: result)
    }

    var openMoments: [ConfirmationMoment] {
        moments.filter { !selection.resolvedMoments.contains($0.id) }
    }

    var totalPhotos: Int { result?.analyzed.count ?? trip.photoCount }

    func photo(_ id: PhotoID) -> AnalyzedPhoto? {
        result?.analyzed.first { $0.id == id }
    }

    func start() {
        guard task == nil else { return }
        let trip = trip
        let flag = cancelFlag
        stage = .reading(done: 0, total: trip.photoCount)
        task = Task { [weak self] in
            do {
                let outcome = try await Self.cull(trip: trip, cancel: flag) { event in
                    Task { @MainActor in self?.stage = event }
                }
                guard let self else { return }
                self.result = outcome.result
                self.index = outcome.index
                self.skippedUtility = outcome.index.utilityCount
                self.selection = KeeperSelection(result: outcome.result)
                let rows = CuratedRow.rows(for: outcome.result)
                self.moments = ConfirmationBuilder.build(
                    result: outcome.result,
                    rows: rows,
                    groups: PhotoGroupIndex.build(outcome.result.grouping)
                ).moments
                self.stage = .ready
            } catch is CancellationError {
                self?.stage = .idle
            } catch {
                self?.stage = .failed(error.localizedDescription)
            }
            self?.task = nil
        }
    }

    func cancel() {
        cancelFlag.cancel()
        task?.cancel()
    }

    func swipe(_ action: ConfirmationAction, on moment: ConfirmationMoment) {
        selection.apply(action, to: moment)
    }

    func toggle(_ id: PhotoID) {
        selection.toggle(id)
    }

    func saveAlbum() async {
        guard let result else { return }
        let identifiers = index.localIdentifiers(for: Array(selection.keepers), in: result)
        let title = "Photocore · " + trip.title
        do {
            try await PhotoLibraryWriter.saveAlbum(title: title, localIdentifiers: identifiers, markFavorite: false)
            stage = .saved(albumTitle: title)
        } catch {
            stage = .failed("Could not save the album: \(error.localizedDescription)")
        }
    }

    private struct Outcome: Sendable {
        var result: PipelineResult
        var index: LibraryExportIndex
    }

    nonisolated private static func cull(
        trip: TripSummary,
        cancel: CancelFlag,
        report: @escaping @Sendable (Stage) -> Void
    ) async throws -> Outcome {
        let base = try PhotoLibraryIngest.workingFolder(named: trip.id)
        let photos = base.appendingPathComponent("photos", isDirectory: true)
        let output = base.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)

        let assets = PhotoLibraryIngest.fetchPhotos(
            from: trip.start.addingTimeInterval(-1),
            to: trip.end.addingTimeInterval(1)
        )
        _ = try await PhotoLibraryIngest.export(assets, to: photos) { done, total in
            report(.reading(done: done, total: total))
        }
        try Task.checkCancellation()
        let index = LibraryExportIndex.load(from: photos)

        var profile = ScoringProfile.default(for: .trip)
        profile.sizingMode = .percentage
        profile.keepPercentage = 20
        var runner = PhotoPipelineRunner()
        runner.checkpointInterval = 32
        let result = try await Task.detached(priority: .userInitiated) {
            try runner.run(
                folder: photos,
                outputDirectory: output,
                profile: profile,
                exportSpecification: ExportSpecification(preset: .compact),
                progress: { event in
                    if event.stage == .analyzing {
                        report(.culling(done: event.completed, total: event.total))
                    }
                },
                shouldCancel: { cancel.isCancelled }
            )
        }.value
        return Outcome(result: result, index: index)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}
