import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// `photo-engine compare-render <manifest.json> [--count 6] [--sheet out.jpg]`
/// Renders as-shot, RAW+auto, and camera-JPEG+auto side by side.
enum RenderComparison {
    static func run(manifest manifestURL: URL, count: Int, sheet: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PipelineManifest.self, from: data)
        let analyzedByID = Dictionary(uniqueKeysWithValues: manifest.analyzed.map { ($0.id, $0) })
        let selected = manifest.shortlist.selectedIDs.compactMap { analyzedByID[$0] }
        guard !selected.isEmpty else {
            throw PhotoEngineError.invalidArgument("Manifest has no selected photos.")
        }
        let picks = evenlySpaced(selected, count: max(1, count))
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("photocore-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let renderer = ApplePhotoRenderer()
        var cells: [ContactSheet.Cell] = []
        for photo in picks {
            let asShot = PhotoFormatSupport.companionJPEG(for: photo.asset.url) ?? photo.asset.url
            cells.append(.init(url: asShot, label: "\(photo.asset.url.lastPathComponent) as shot"))

            var rawRecipe = ApplePhotoRenderer.recipe(for: photo, style: .natural)
            rawRecipe.base = .raw
            let rawURL = temp.appendingPathComponent("\(photo.id.description)-raw.jpg")
            let rawData = try renderer.previewJPEG(photo: photo, recipe: rawRecipe, maxLongEdge: 900)
            try rawData.write(to: rawURL)
            cells.append(.init(url: rawURL, label: "RAW + auto"))

            var cameraRecipe = rawRecipe
            cameraRecipe.base = .cameraJPEG
            let cameraURL = temp.appendingPathComponent("\(photo.id.description)-camera.jpg")
            let cameraData = try renderer.previewJPEG(photo: photo, recipe: cameraRecipe, maxLongEdge: 900)
            try cameraData.write(to: cameraURL)
            cells.append(.init(url: cameraURL, label: "camera + auto"))
        }
        try ContactSheet.write(cells, columns: 3, cellSize: 520, to: sheet)
        print("Contact sheet: \(sheet.path)")
    }

    private static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        if count == 1 { return [items[items.count / 2]] }
        return (0..<count).map { index in
            let position = Double(index) * Double(items.count - 1) / Double(count - 1)
            return items[Int(position.rounded())]
        }
    }
}
