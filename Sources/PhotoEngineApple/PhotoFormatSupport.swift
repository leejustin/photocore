import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

import PhotoEngineCore

public enum PhotoFormatSupport {
    public static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "crw", "dng", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "srf", "srw", "3fr", "fff"
    ]

    public static let renderedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif"
    ]

    public static func isSupportedImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return rawExtensions.contains(ext) || renderedExtensions.contains(ext)
    }

    public static func format(for url: URL) -> PhotoFormat {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic": return .heic
        case "heif": return .heif
        case "dng": return .dng
        case let ext where rawExtensions.contains(ext): return .raw
        default:         return .unknown
        }
    }

    /// The camera's own JPEG shot alongside a RAW master (same folder and file stem).
    public static func companionJPEG(for rawURL: URL) -> URL? {
        let stem = rawURL.deletingPathExtension()
        for ext in ["JPG", "jpg", "JPEG", "jpeg"] {
            let candidate = stem.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func shouldSkipImport(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix(".") { return true }
        if name.contains("screenshot") { return true }
        if name.hasPrefix("screen recording") { return true }
        if name.hasPrefix("img_e") && (name.hasSuffix(".heic") || name.hasSuffix(".jpg")) {
            // Prefer the non-edited original when both exist; still import if alone.
            return false
        }
        // Live Photo motion companions are not stills.
        if ["mov", "mp4", "m4v", "aae"].contains(url.pathExtension.lowercased()) { return true }
        return false
    }

    public static func pairingKey(for url: URL, root: URL) -> String {
        let relative = relativePath(for: url, root: root)
        let dir = (relative as NSString).deletingLastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return "\(dir.lowercased())/\(stem)"
    }

    public static func preferMaster(in urls: [URL]) -> URL {
        let ranked = urls.sorted { lhs, rhs in
            let left = priority(for: lhs)
            let right = priority(for: rhs)
            if left != right { return left > right }
            return lhs.path < rhs.path
        }
        return ranked[0]
    }

    private static func priority(for url: URL) -> Int {
        switch format(for: url) {
        case .raw: return 40
        case .dng: return 35
        case .heic, .heif: return 20
        case .jpeg: return 10
        case .unknown: return 0
        }
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }
}

/// Disk-backed JPEG previews so RAW folders stay snappy after the first pass.
public final class PreviewDiskCache: @unchecked Sendable {
    public static let shared = PreviewDiskCache()

    private let root: URL
    private let lock = NSLock()

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = caches.appendingPathComponent("Photocore/previews", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func jpegPreview(for url: URL, maxPixelSize: Int) throws -> Data {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        let file = root.appendingPathComponent(key).appendingPathExtension("jpg")
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            return data
        }
        let data = try ImageMetadataReader.thumbnailData(url: url, maxPixelSize: maxPixelSize, preferEmbedded: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    private func cacheKey(for url: URL, maxPixelSize: Int) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let mtime = Int((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        let material = "\(url.standardizedFileURL.path)|\(size)|\(mtime)|\(maxPixelSize)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
