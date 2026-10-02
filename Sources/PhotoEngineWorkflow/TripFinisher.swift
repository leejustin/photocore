import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// The paid finish, end to end: the owner's keepers (already culled on the
/// phone) plus everyone else's photos, each person culled on their own and then
/// curated together (`GroupCuration`), then facts, the diary, finished photos,
/// the book page and the Instagram pack.
public enum TripFinisher {
    /// One person's uploads. A nil name is an unnamed guest from an older book.
    public struct Contributor: Sendable {
        public var name: String?
        public var folder: URL

        public init(name: String?, folder: URL) {
            self.name = name
            self.folder = folder
        }
    }

    public struct Folders: Sendable {
        public var owner: URL
        public var contributors: [Contributor]
        public var book: URL
        public var work: URL

        public init(owner: URL, contributors: [Contributor], book: URL, work: URL) {
            self.owner = owner
            self.contributors = contributors
            self.book = book
            self.work = work
        }

        public init(owner: URL, guests: URL, book: URL, work: URL) {
            self.init(owner: owner, contributors: [Contributor(name: nil, folder: guests)], book: book, work: work)
        }
    }

    public struct Outcome: Sendable {
        public var book: TripBook
        public var report: BookPublisher.Report
        public var ownerCount: Int
        /// Contributor photos in the book.
        public var guestKept: Int
        /// Contributor photos left out because someone had a better shot of the moment.
        public var guestDuplicates: Int
        /// Contributor photos left out to keep the book a good length.
        public var guestOverBudget: Int
        /// Photos in the book per contributor name.
        public var keptPerContributor: [String: Int]
    }

    /// Visual distance under which two frames count as the same shot
    /// (revision-2 feature prints; see the README calibration).
    public static let duplicateDistance = GroupCuration.duplicateDistance

    public static func finish(
        folders: Folders,
        title: String?,
        context: TripContext = .empty,
        tone: DiaryTone,
        theme: BookTheme,
        ownerName: String? = nil,
        writer: any DiaryWriter,
        options: BookRenderer.Options,
        lookUpPlaces: Bool = true,
        guestKeepPercent: Double = 30,
        progress: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> Outcome {
        let fm = FileManager.default
        try fm.createDirectory(at: folders.work, withIntermediateDirectories: true)
        let runner = PhotoPipelineRunner()

        progress("Reading your photos", 0, 1)
        var everything = ScoringProfile.default(for: .trip)
        everything.sizingMode = .percentage
        everything.keepPercentage = 90
        func photos(in folder: URL) -> Int {
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        }
        var owner: [AnalyzedPhoto] = []
        if photos(in: folders.owner) > 0 {
            owner = try runner.run(folder: folders.owner, outputDirectory: folders.work.appendingPathComponent("owner", isDirectory: true), profile: everything, exportSpecification: ExportSpecification(preset: .compact)).analyzed
        }
        var keepers = owner
        var credits: [PhotoID: String] = [:]
        if let ownerName, !ownerName.isEmpty { for photo in owner { credits[photo.id] = ownerName } }

        // Each person's own best first, so everyone arrives on equal terms.
        var picks: [GroupCuration.Candidate] = []
        var byID: [PhotoID: AnalyzedPhoto] = [:]
        let people = folders.contributors.filter { photos(in: $0.folder) > 0 }
        for (index, person) in people.enumerated() {
            progress("Picking the best of everyone's photos", index, people.count)
            var profile = ScoringProfile.default(for: .trip)
            profile.sizingMode = .percentage
            profile.keepPercentage = guestKeepPercent
            let result = try runner.run(folder: person.folder, outputDirectory: folders.work.appendingPathComponent("contributor-\(index)", isDirectory: true), profile: profile, exportSpecification: ExportSpecification(preset: .compact))
            let scores = Dictionary(result.shortlist.decisions.map { ($0.photoID, $0.score) }, uniquingKeysWith: max)
            for photo in KeeperSelection(result: result).ordered(in: result) {
                byID[photo.id] = photo
                if let name = person.name { credits[photo.id] = name }
                picks.append(GroupCuration.Candidate(id: photo.id, contributor: person.name ?? "guest-\(index)", score: scores[photo.id] ?? 0, captureDate: photo.asset.metadata.captureDate))
            }
        }
        var guestKept = 0, guestDuplicates = 0, guestOverBudget = 0
        var keptPerContributor: [String: Int] = [:]
        if !picks.isEmpty {
            progress("Choosing the best shot of each moment", 0, 1)
            let distance = AppleVisualDistance.cachedProvider()
            var signals = Dictionary(owner.map { ($0.id, $0.signals) }, uniquingKeysWith: { a, _ in a })
            for (id, photo) in byID { signals[id] = photo.signals }
            let ownerCandidates = owner.map { GroupCuration.Candidate(id: $0.id, contributor: nil, score: .infinity, captureDate: $0.asset.metadata.captureDate) }
            let outcome = GroupCuration.curate(owner: ownerCandidates, contributors: picks) { a, b in
                guard let x = signals[a], let y = signals[b] else { return nil }
                return distance(x, y)
            }
            keepers.append(contentsOf: outcome.kept.compactMap { byID[$0] })
            guestKept = outcome.kept.count
            guestDuplicates = outcome.repeats.count
            guestOverBudget = outcome.overBudget.count
            for id in outcome.kept { if let name = credits[id] { keptPerContributor[name, default: 0] += 1 } }
        }
        guard !keepers.isEmpty else { throw FinishError.noPhotos }

        progress("Reading scenes and places", 0, keepers.count)
        let facts = await TripFactsBuilder.build(keepers: keepers, lookUpPlaces: lookUpPlaces) { done, total in
            progress("Reading scenes and places", done, total)
        }
        try facts.save(to: folders.book)
        let sources = Dictionary(keepers.map { ($0.id, $0.asset.url) }, uniquingKeysWith: { a, _ in a })

        progress("Reading signs and landmarks", 0, keepers.count)
        let enrichment = await TripEnricher.enrich(facts: facts, source: { sources[$0.id] }, lookUpNearby: lookUpPlaces)

        progress("Writing the diary", 0, 1)
        var book = await TripBookComposer.compose(
            facts: facts,
            writer: writer,
            enrichment: enrichment,
            context: context,
            thumbnail: { sources[$0.id].flatMap { TripBookComposer.thumbnailData(url: $0) } },
            tone: tone,
            theme: theme
        )
        if let title, !title.isEmpty { book.title = title }
        book.credit(credits)

        progress("Finishing photos", 0, keepers.count)
        let edits = BookEdits.load(from: folders.book)
        let report = try BookPublisher.publish(book: book, edits: edits, facts: facts, source: { sources[$0.id] }, to: folders.book, options: options)
        return Outcome(book: book, report: report, ownerCount: owner.count, guestKept: guestKept, guestDuplicates: guestDuplicates, guestOverBudget: guestOverBudget, keptPerContributor: keptPerContributor)
    }

    /// Applies one owner edit and re-renders the page without touching photos.
    public static func applyEdit(key: String, value: String, bookFolder: URL, options: BookRenderer.Options) throws {
        guard BookEdits.isAllowed(key: key) else { throw EditError.notEditable }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= BookEdits.maximumLength else { throw EditError.tooLong }
        let book = try TripBook.load(from: bookFolder)
        var edits = BookEdits.load(from: bookFolder)
        edits.values[key] = trimmed
        try edits.save(to: bookFolder)
        try Data(BookRenderer.html(edits.applied(to: book), options: options).utf8)
            .write(to: bookFolder.appendingPathComponent("index.html"), options: .atomic)
    }

    public enum FinishError: Error, Equatable {
        case noPhotos
    }

    public enum EditError: Error, Equatable {
        case notEditable
        case tooLong
    }
}
