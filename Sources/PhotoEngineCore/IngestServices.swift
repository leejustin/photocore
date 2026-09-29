import Foundation

public struct RenameToken: Sendable, Equatable {
    public var shootName: String
    public var sequence: Int
    public var captureDate: Date?
    public var originalName: String
    public var cameraModel: String?

    public init(shootName: String, sequence: Int, captureDate: Date?, originalName: String, cameraModel: String?) {
        self.shootName = shootName
        self.sequence = sequence
        self.captureDate = captureDate
        self.originalName = originalName
        self.cameraModel = cameraModel
    }
}

public enum BatchRename {
    /// Pattern tokens: `{shoot}` `{seq:3}` `{yyyy}` `{MM}` `{dd}` `{HH}` `{mm}` `{ss}` `{name}` `{camera}`
    public static func apply(pattern: String, token: RenameToken, ext: String) -> String {
        var result = pattern
        result = result.replacingOccurrences(of: "{shoot}", with: sanitize(token.shootName))
        result = result.replacingOccurrences(of: "{name}", with: sanitize(URL(fileURLWithPath: token.originalName).deletingPathExtension().lastPathComponent))
        result = result.replacingOccurrences(of: "{camera}", with: sanitize(token.cameraModel ?? "cam"))
        if let date = token.captureDate {
            let cal = Calendar.current
            let parts: [(String, Int)] = [
                ("{yyyy}", cal.component(.year, from: date)),
                ("{MM}", cal.component(.month, from: date)),
                ("{dd}", cal.component(.day, from: date)),
                ("{HH}", cal.component(.hour, from: date)),
                ("{mm}", cal.component(.minute, from: date)),
                ("{ss}", cal.component(.second, from: date))
            ]
            for (key, value) in parts {
                let width = key.contains("yyyy") ? 4 : 2
                result = result.replacingOccurrences(of: key, with: String(format: "%0\(width)d", value))
            }
        } else {
            for key in ["{yyyy}", "{MM}", "{dd}", "{HH}", "{mm}", "{ss}"] {
                result = result.replacingOccurrences(of: key, with: "00")
            }
        }
        if let match = result.range(of: #"\{seq:\d+\}"#, options: .regularExpression) {
            let spec = String(result[match])
            let n = Int(spec.dropFirst(5).dropLast(1)) ?? 3
            result.replaceSubrange(match, with: String(format: "%0\(max(1, n))d", token.sequence))
        } else {
            result = result.replacingOccurrences(of: "{seq}", with: String(format: "%03d", token.sequence))
        }
        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        if result.lowercased().hasSuffix(".\(cleanExt.lowercased())") { return result }
        return "\(result).\(cleanExt)"
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
    }
}

public struct WatchFolderEvent: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Bool

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// Lightweight polling watcher — no FSEvents dependency, good enough for card dumps.
public final class FolderWatcher: @unchecked Sendable {
    private let folder: URL
    private var known = Set<String>()
    private let queue = DispatchQueue(label: "photocore.folder-watcher")

    public init(folder: URL) {
        self.folder = folder
        known = currentPaths()
    }

    public func poll() -> [WatchFolderEvent] {
        queue.sync {
            let now = currentPaths()
            let added = now.subtracting(known)
            known = now
            return added.sorted().map { path in
                let url = URL(fileURLWithPath: path)
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return WatchFolderEvent(url: url, isDirectory: isDir)
            }
        }
    }

    private func currentPaths() -> Set<String> {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return Set(items.map(\.path))
    }
}

public enum MetadataStamp {
    public static func applyKeywords(_ keywords: [String], into existing: String?) -> String {
        let items = keywords.map { "    <rdf:li>\(escape($0))</rdf:li>" }.joined(separator: "\n")
        if let existing, existing.contains("dc:subject") {
            return existing
        }
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Photocore Ingest">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:subject>
            <rdf:Bag>
        \(items)
            </rdf:Bag>
           </dc:subject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
