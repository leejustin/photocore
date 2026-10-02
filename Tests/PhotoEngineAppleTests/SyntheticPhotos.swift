import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes small, visually distinct JPEGs so the real Vision pipeline can run in tests
/// on macOS and on the iOS simulator without committing private photographs.
enum SyntheticPhotos {
    static func makeFolder(count: Int, duplicateEvery: Int = 0) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photocore-synthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<count {
            let seed = duplicateEvery > 0 && index % duplicateEvery == 1 ? index - 1 : index
            let url = folder.appendingPathComponent(String(format: "IMG_%04d.jpg", index))
            try writeJPEG(seed: seed, to: url)
        }
        return folder
    }

    static func writeJPEG(seed: Int, to url: URL, width: Int = 640, height: Int = 480) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        var rng = SplitMix(seed: UInt64(seed + 1))
        context.setFillColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<8 {
            context.setFillColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1)
            let rect = CGRect(
                x: rng.unit() * Double(width), y: rng.unit() * Double(height),
                width: 40 + rng.unit() * 260, height: 40 + rng.unit() * 220
            )
            if rng.unit() > 0.5 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let date = Date(timeIntervalSince1970: 1_780_000_000 + Double(seed) * 90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date)]
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyExifDictionary: exif
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() % 10_000) / 10_000 }
}
