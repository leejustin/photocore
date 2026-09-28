import Foundation
import PhotoEngineApple
import PhotoEngineCore

public struct DeliveryJob: Sendable {
    public let photo: AnalyzedPhoto
    public let fileName: String
    public let mark: PhotoReviewMark
    public let customRecipe: EditRecipe?
    public let reusableExport: URL?

    public init(photo: AnalyzedPhoto, fileName: String, mark: PhotoReviewMark, customRecipe: EditRecipe?, reusableExport: URL?) {
        self.photo = photo
        self.fileName = fileName
        self.mark = mark
        self.customRecipe = customRecipe
        self.reusableExport = reusableExport
    }
}

public struct SidecarJob: Sendable {
    public let mark: PhotoReviewMark
    public let baseName: String
    public let folder: URL

    public init(mark: PhotoReviewMark, baseName: String, folder: URL) {
        self.mark = mark
        self.baseName = baseName
        self.folder = folder
    }
}

public struct DeliveryReport: Equatable, Sendable {
    public let folder: URL
    public let photoCount: Int
    public let sidecarsWritten: Int
    public let sidecarsSkipped: Int

    public init(folder: URL, photoCount: Int, sidecarsWritten: Int, sidecarsSkipped: Int) {
        self.folder = folder
        self.photoCount = photoCount
        self.sidecarsWritten = sidecarsWritten
        self.sidecarsSkipped = sidecarsSkipped
    }
}

public enum DeliveryExecutor {
    public static func run(
        jobs: [DeliveryJob],
        sidecars: [SidecarJob],
        entries: [PortableCullEntry],
        destination: URL,
        look: AlbumLook,
        specification: ExportSpecification,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> DeliveryReport {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let renderer = ApplePhotoRenderer()
        for (index, job) in jobs.enumerated() {
            let output = destination.appendingPathComponent(job.fileName)
            if let reusable = job.reusableExport, fileManager.fileExists(atPath: reusable.path) {
                try fileManager.copyItem(at: reusable, to: output)
            } else {
                let recipe: EditRecipe
                if let custom = job.customRecipe {
                    recipe = custom
                } else {
                    let horizon = look.autoStraighten
                        ? ApplePhotoRenderer.detectHorizonDegrees(url: job.photo.asset.url, orientation: job.photo.asset.metadata.orientation)
                        : nil
                    recipe = look.recipe(for: job.photo, horizonDegrees: horizon)
                }
                _ = try renderer.render(photo: job.photo, outputURL: output, recipe: recipe, exportSpecification: specification)
            }
            try JPEGRatingStamp.stamp(job.mark, into: output)
            progress(index + 1, jobs.count)
        }
        var written = 0
        var skipped = 0
        for sidecar in sidecars {
            switch try LightroomSidecar.writePreservingExisting(sidecar.mark, named: sidecar.baseName, to: sidecar.folder) {
            case .written: written += 1
            case .skippedExistingSidecar: skipped += 1
            }
        }
        try LightroomSidecar.decisionsData(entries)
            .write(to: destination.appendingPathComponent("photocore-cull.json"), options: .atomic)
        return DeliveryReport(folder: destination, photoCount: jobs.count, sidecarsWritten: written, sidecarsSkipped: skipped)
    }

    /// Always a brand-new folder, so delivery never overwrites or deletes anything.
    public static func newFolder(parent: URL, shootName: String, now: Date = Date()) -> URL {
        let day = now.formatted(.iso8601.year().month().day())
        let base = "\(shootName) \(day)"
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
