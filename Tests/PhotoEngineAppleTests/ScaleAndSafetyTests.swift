import CoreGraphics
import Foundation
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow
import Testing

/// Counts thumbnail requests so tests can prove a resumed cull reads nothing twice.
final class CountingSource: TripPhotoSource, @unchecked Sendable {
    let inner: FolderTripSource
    private let lock = NSLock()
    private var count = 0
    init(_ inner: FolderTripSource) { self.inner = inner }
    var items: [TripPhotoItem] { inner.items }
    var requests: Int { lock.withLock { count } }
    func thumbnail(for item: TripPhotoItem, maxPixel: Int) async -> CGImage? {
        lock.withLock { count += 1 }
        return await inner.thumbnail(for: item, maxPixel: maxPixel)
    }
}

extension VisionSuites {
    @Suite("Streamed cull")
    struct StreamedCullTests {
        @Test("culls without working copies and resumes without rereading")
        func streamedCull() async throws {
            let folder = try SyntheticPhotos.makeFolder(count: 14, duplicateEvery: 3)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: store) }
            var profile = ScoringProfile.default(for: .trip)
            profile.sizingMode = .percentage
            profile.keepPercentage = 30

            let source = CountingSource(try FolderTripSource(folder: folder))
            var culler = StreamedCuller()
            culler.conditions = { DeviceConditions(freeBytes: 10_000_000_000, thermal: .nominal, lowPower: false) }
            let first = try await culler.cull(source: source, storeFolder: store, profile: profile)
            #expect(first.result.analyzed.count == 14)
            #expect(!first.result.shortlist.selectedIDs.isEmpty)
            #expect(first.identifiers(for: first.result.shortlist.selectedIDs).count == first.result.shortlist.selectedIDs.count)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.path) == [TripSignalStore.fileName], "the cull left files besides the analysis store")
            let storeBytes = try #require(try FileManager.default.attributesOfItem(atPath: store.appendingPathComponent(TripSignalStore.fileName).path)[.size] as? Int)
            #expect(storeBytes / 14 < 20_000, "analysis store is \(storeBytes / 14) bytes per photo")
            #expect(source.requests == 14)

            let second = try await culler.cull(source: source, storeFolder: store, profile: profile)
            #expect(source.requests == 14, "a resumed cull read thumbnails again")
            #expect(Set(second.identifiers(for: second.result.shortlist.selectedIDs)) == Set(first.identifiers(for: first.result.shortlist.selectedIDs)))
        }

        @Test("a full disk refuses before any work")
        func refusesWhenFull() async throws {
            let folder = try SyntheticPhotos.makeFolder(count: 2)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = CountingSource(try FolderTripSource(folder: folder))
            var culler = StreamedCuller()
            culler.conditions = { DeviceConditions(freeBytes: 50_000_000, thermal: .nominal, lowPower: false) }
            await #expect(throws: StreamedCullError.self) {
                _ = try await culler.cull(source: source, storeFolder: FileManager.default.temporaryDirectory.appendingPathComponent("full-\(UUID().uuidString)"), profile: .default(for: .trip))
            }
            #expect(source.requests == 0)
        }
    }
}

@Suite("Scale and safety rules")
struct ScaleAndSafetyRuleTests {
    @Test("guards refuse, pause and slow down")
    func guards() {
        #expect(CullGuard.check(DeviceConditions(freeBytes: 100_000_000, thermal: .nominal, lowPower: false)) == .refuse(reason: "Your iPhone needs about 200 MB free to cull. Free a little space and try again."))
        if case .pause = CullGuard.check(DeviceConditions(freeBytes: nil, thermal: .serious, lowPower: false)) {} else { Issue.record("a hot phone did not pause") }
        #expect(CullGuard.check(DeviceConditions(freeBytes: 1_000_000_000, thermal: .fair, lowPower: false)) == .go(batchSize: 48))
        #expect(CullGuard.check(DeviceConditions(freeBytes: 1_000_000_000, thermal: .nominal, lowPower: true)) == .go(batchSize: 12))
    }

    @Test("keepers and protected photos are never set aside")
    func planner() {
        let plan = SetAsidePlanner.plan(
            candidates: ["a", "b", "c", "d", "e", "f"],
            keepers: ["a"],
            protection: ["b": LibraryProtection(isFavorite: true), "c": LibraryProtection(isEdited: true), "d": LibraryProtection(isInOtherAlbum: true), "e": LibraryProtection(isShared: true)]
        )
        #expect(plan.eligible == ["f"])
        #expect(plan.protected == ["b": "favorite", "c": "edited", "d": "in an album", "e": "shared"])
    }

    @Test("one delete tap is capped")
    func deleteCap() {
        let ids = (0..<1_234).map { "p\($0)" }
        let batches = SetAsidePlanner.deleteBatches(ids)
        #expect(batches.map(\.count) == [500, 500, 234])
        #expect(SetAsidePlanner.deleteBatches([]).isEmpty)
    }

    @Test("the log tracks each photo's latest state")
    func log() throws {
        var log = SetAsideLog()
        let t0 = Date(timeIntervalSince1970: 1_000)
        log.record(["a", "b", "c"], tripID: "t1", state: .setAside, at: t0)
        log.record(["b"], tripID: "t1", state: .restored, at: t0.addingTimeInterval(60))
        log.record(["c"], tripID: "t1", state: .deleted, at: t0.addingTimeInterval(120))
        log.record(["z"], tripID: "t2", state: .setAside, at: t0)
        #expect(log.currentlySetAside(tripID: "t1") == ["a"])
        #expect(Set(log.currentlySetAside()) == ["a", "z"])
        #expect(log.deleted().map(\.identifier) == ["c"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try log.save(to: url)
        #expect(SetAsideLog.load(from: url) == log)
    }
}
