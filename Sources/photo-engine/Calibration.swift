import CoreGraphics
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore

/// `photo-engine calibrate <folder> [--sheet out.jpg]`
/// Measures Vision distances between neighbouring frames and between unrelated frames,
/// so grouping thresholds can be checked against a real shoot.
enum Calibration {
    struct Frame {
        let url: URL
        let time: Double
        let featurePrint: Data
    }

    struct Pair {
        let a: Frame
        let b: Frame
        let gap: Double
        let distance: Double
    }

    static let analysisPixelSize = 1024

    static func run(folder: URL, sheet: URL?) throws {
        let frames = try loadFrames(folder)
        guard frames.count >= 3 else {
            throw PhotoEngineError.invalidArgument("Need at least 3 photos with capture dates in \(folder.path).")
        }
        var neighbours: [Pair] = []
        for i in frames.indices {
            for j in (i + 1)..<min(i + 4, frames.count) {
                guard let d = AppleVisualDistance.distance(frames[i].featurePrint, frames[j].featurePrint) else { continue }
                neighbours.append(Pair(a: frames[i], b: frames[j], gap: frames[j].time - frames[i].time, distance: d))
            }
        }
        var unrelated: [Double] = []
        var generator = SystemRandomNumberGenerator()
        var attempts = 0
        while unrelated.count < 200, attempts < 20_000 {
            attempts += 1
            let a = Int.random(in: frames.indices, using: &generator)
            let b = Int.random(in: frames.indices, using: &generator)
            guard abs(frames[a].time - frames[b].time) > 300,
                  let d = AppleVisualDistance.distance(frames[a].featurePrint, frames[b].featurePrint) else { continue }
            unrelated.append(d)
        }

        let within3 = neighbours.filter { $0.gap <= 3 }.map(\.distance).sorted()
        let within15 = neighbours.filter { $0.gap <= 15 }.map(\.distance).sorted()
        unrelated.sort()
        print("Frames: \(frames.count)")
        report("Neighbours ≤3s ", within3, [0.10, 0.25, 0.50, 0.75, 0.90])
        report("Neighbours ≤15s", within15, [0.10, 0.25, 0.50, 0.75, 0.90])
        report("Unrelated >5min", unrelated, [0.01, 0.05, 0.10, 0.50])
        if !within3.isEmpty, !unrelated.isEmpty {
            let sameShot = min(percentile(within3, 0.75), percentile(unrelated, 0.01) - 0.05)
            let sameMoment = min(percentile(within3, 0.90), percentile(unrelated, 0.05))
            print(String(format: "Suggested nearDuplicateVisualDistance ≈ %.2f, momentVisualDistance ≈ %.2f", sameShot, sameMoment))
        }

        if let sheet {
            let targets = [0.30, 0.40, 0.47, 0.52, 0.57, 0.62, 0.70]
            var used = Set<URL>()
            var cells: [ContactSheet.Cell] = []
            for target in targets {
                guard let pair = neighbours
                    .filter({ !used.contains($0.a.url) })
                    .min(by: { abs($0.distance - target) < abs($1.distance - target) }) else { continue }
                used.insert(pair.a.url)
                cells.append(.init(url: pair.a.url, label: String(format: "%@  d=%.2f  gap=%.1fs", pair.a.url.lastPathComponent, pair.distance, pair.gap)))
                cells.append(.init(url: pair.b.url, label: pair.b.url.lastPathComponent))
            }
            try ContactSheet.write(cells, columns: 2, cellSize: 420, to: sheet)
            print("Contact sheet: \(sheet.path)")
        }
    }

    private static func report(_ title: String, _ values: [Double], _ quantiles: [Double]) {
        guard !values.isEmpty else {
            print("\(title): no pairs")
            return
        }
        let parts = quantiles.map { String(format: "p%.0f %.2f", $0 * 100, percentile(values, $0)) }
        print("\(title) (n=\(values.count)): " + parts.joined(separator: "  "))
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }

    /// One frame per capture: prefers JPEG/HEIC over a RAW with the same stem (faster, same content).
    private static func loadFrames(_ folder: URL) throws -> [Frame] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            throw PhotoEngineError.invalidFolder(folder)
        }
        var byStem: [String: URL] = [:]
        for case let url as URL in enumerator where PhotoFolderImporter.isSupportedImage(url) {
            let stem = url.deletingPathExtension().path
            let isRaw = ["arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng"].contains(url.pathExtension.lowercased())
            if byStem[stem] == nil || !isRaw { byStem[stem] = url }
        }
        var frames: [Frame] = []
        for url in byStem.values {
            guard let time = captureTime(url),
                  let image = ContactSheet.thumbnail(url, maxPixelSize: analysisPixelSize),
                  let print = try AppleVisualDistance.featurePrintData(for: image) else { continue }
            frames.append(Frame(url: url, time: time, featurePrint: print))
        }
        return frames.sorted { $0.time < $1.time }
    }

    private static func captureTime(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: original) else { return nil }
        let subseconds = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String).flatMap { Double("0." + $0) } ?? 0
        return date.timeIntervalSince1970 + subseconds
    }
}
