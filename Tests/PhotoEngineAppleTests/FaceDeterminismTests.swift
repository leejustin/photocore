import CoreGraphics
import Foundation
import ImageIO
import PhotoEngineApple
import PhotoEngineCore
import Testing
import UniformTypeIdentifiers

extension VisionSuites {
    /// Face count and face quality feed the keeper decision, so analyzing the
    /// same photo twice must give the same answer. Vision's face detector is
    /// noisy on borderline faces; see the 2026-10-01 entries in
    /// outputs/evaluation-log.md.
    @Suite("Face signal determinism")
    struct FaceDeterminismTests {
        @Test("drawn faces analyze identically on every run")
        func drawnFacesAreStable() throws {
            let folder = try DrawnFaces.makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jpg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let report = try Self.compare(urls: urls, runs: 4)
            #expect(report.unstable.isEmpty, "\(report.unstable.joined(separator: "\n"))")
            // Guard against a vacuous pass: at least one drawing must read as a face.
            #expect(report.photosWithFaces > 0, "Vision found no face in any drawing")
        }

        /// Real-photo probe. Point PHOTOCORE_DET_DIR at a folder of JPEGs;
        /// PHOTOCORE_DET_RUNS sets the number of passes (default 4). Every
        /// other pass runs in parallel, matching how the pipeline analyzes.
        @Test(
            "real photos analyze identically on every run",
            .enabled(if: ProcessInfo.processInfo.environment["PHOTOCORE_DET_DIR"] != nil)
        )
        func realPhotosAreStable() throws {
            let environment = ProcessInfo.processInfo.environment
            let folder = URL(fileURLWithPath: try #require(environment["PHOTOCORE_DET_DIR"]))
            let runs = environment["PHOTOCORE_DET_RUNS"].flatMap(Int.init) ?? 4
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            try #require(!urls.isEmpty)
            let report = try Self.compare(urls: urls, runs: runs, parallelEveryOther: true)
            print("face determinism: \(urls.count) photos × \(runs) runs, \(report.photosWithFaces) with faces, \(report.unstable.count) unstable")
            #expect(report.unstable.isEmpty, "\(report.unstable.joined(separator: "\n"))")
        }

        struct Report {
            var unstable: [String] = []
            var photosWithFaces = 0
        }

        static func compare(urls: [URL], runs: Int, parallelEveryOther: Bool = false) throws -> Report {
            let engine = AppleAnalysisEngine()
            let inputs = try urls.map { url -> (PhotoAsset, Data) in
                let asset = PhotoAsset(
                    url: url,
                    relativePath: url.lastPathComponent,
                    metadata: PhotoMetadata(pixelWidth: 0, pixelHeight: 0),
                    contentHash: url.lastPathComponent
                )
                return (asset, try PhotoThumbnailProvider.data(for: url, maxPixelSize: AppleAnalysisEngine.analysisPixelSize))
            }
            func pass(parallel: Bool) throws -> [AnalysisSignals] {
                guard parallel else { return try inputs.map { try engine.analyze(asset: $0.0, thumbnailData: $0.1) } }
                let results = Locked([AnalysisSignals?](repeating: nil, count: inputs.count))
                let failure = Locked<Error?>(nil)
                DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
                    do {
                        let signals = try engine.analyze(asset: inputs[index].0, thumbnailData: inputs[index].1)
                        results.update { $0[index] = signals }
                    } catch {
                        failure.update { $0 = error }
                    }
                }
                if let error = failure.value { throw error }
                return results.value.compactMap { $0 }
            }

            let baseline = try pass(parallel: false)
            var report = Report(photosWithFaces: baseline.filter { $0.faceCount > 0 }.count)
            var unstable = Set<String>()
            for run in 1..<max(runs, 2) {
                let again = try pass(parallel: parallelEveryOther && run % 2 == 1)
                for (index, (before, after)) in zip(baseline, again).enumerated()
                where before.faceCount != after.faceCount || before.faceQuality != after.faceQuality {
                    let name = urls[index].lastPathComponent
                    unstable.insert(name)
                    report.unstable.append(
                        "\(name) run \(run + 1): faces \(before.faceCount)→\(after.faceCount), quality \(before.faceQuality)→\(after.faceQuality)"
                    )
                }
            }
            report.unstable.sort()
            if !unstable.isEmpty { report.unstable.insert("\(unstable.count) of \(urls.count) photos unstable", at: 0) }
            return report
        }
    }
}

final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// Shaded drawn faces at several sizes, including ones near and below the
/// detector's floor, where run-to-run noise showed up on real photos.
enum DrawnFaces {
    typealias Face = (x: Double, y: Double, height: Double)

    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photocore-faces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let layouts: [(faces: [Face], light: Double)] = [
            ([(512, 384, 150)], 1),
            ([(512, 384, 300)], 1),
            ([(250, 400, 150), (520, 380, 120), (780, 420, 90), (900, 150, 50)], 1),
            ([(512, 384, 100)], 0.55),
            ([(300, 300, 80), (700, 450, 60)], 0.8)
        ]
        for (index, layout) in layouts.enumerated() {
            try write(faces: layout.faces, light: layout.light, to: folder.appendingPathComponent(String(format: "FACE_%02d.jpg", index)))
        }
        return folder
    }

    /// Draws faces on a 1024 × 768 frame; `x`, `y` and `height` are in pixels
    /// and `light` dims the whole frame.
    static func write(faces: [Face], light: Double, to url: URL) throws {
        guard let context = CGContext(
            data: nil, width: 1024, height: 768, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        func color(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
            CGColor(red: r * light, green: g * light, blue: b * light, alpha: 1)
        }
        context.setFillColor(color(0.4, 0.5, 0.6))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        for face in faces {
            let cx = face.x, cy = face.y, h = face.height, w = h * 0.75
            let skin = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [color(0.95, 0.8, 0.68), color(0.6, 0.42, 0.32)] as CFArray,
                locations: [0, 1]
            )!
            context.saveGState()
            context.addEllipse(in: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
            context.clip()
            context.drawRadialGradient(
                skin, startCenter: CGPoint(x: cx, y: cy + h * 0.05), startRadius: 0,
                endCenter: CGPoint(x: cx, y: cy), endRadius: h * 0.55, options: []
            )
            context.restoreGState()
            for side in [-1.0, 1.0] {
                let ex = cx + side * w * 0.2, ey = cy + h * 0.08
                context.setFillColor(color(0.5, 0.35, 0.28))
                context.fillEllipse(in: CGRect(x: ex - w * 0.14, y: ey - h * 0.06, width: w * 0.28, height: h * 0.12))
                context.setFillColor(color(0.97, 0.97, 0.95))
                context.fillEllipse(in: CGRect(x: ex - w * 0.1, y: ey - h * 0.03, width: w * 0.2, height: h * 0.06))
                context.setFillColor(color(0.12, 0.08, 0.05))
                context.fillEllipse(in: CGRect(x: ex - w * 0.035, y: ey - h * 0.03, width: w * 0.07, height: h * 0.06))
                context.setFillColor(color(0.25, 0.15, 0.1))
                context.fill(CGRect(x: ex - w * 0.12, y: ey + h * 0.08, width: w * 0.24, height: h * 0.025))
            }
            context.setFillColor(color(0.6, 0.4, 0.32))
            context.fillEllipse(in: CGRect(x: cx - w * 0.07, y: cy - h * 0.1, width: w * 0.14, height: h * 0.08))
            context.setFillColor(color(0.6, 0.25, 0.25))
            context.fillEllipse(in: CGRect(x: cx - w * 0.17, y: cy - h * 0.27, width: w * 0.34, height: h * 0.07))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
