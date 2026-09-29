import Foundation

public struct CullReport: Codable, Sendable, Equatable {
    public var shootName: String
    public var generatedAt: Date
    public var sourceCount: Int
    public var keptCount: Int
    public var alternateCount: Int
    public var hiddenCount: Int
    public var unusableCount: Int
    public var pickCount: Int
    public var rejectCount: Int
    public var confirmationCount: Int
    public var cameras: [String]
    public var tasteReady: Bool
    public var entries: [PortableCullEntry]

    public init(
        shootName: String,
        generatedAt: Date = Date(),
        sourceCount: Int,
        keptCount: Int,
        alternateCount: Int,
        hiddenCount: Int,
        unusableCount: Int,
        pickCount: Int,
        rejectCount: Int,
        confirmationCount: Int,
        cameras: [String],
        tasteReady: Bool,
        entries: [PortableCullEntry]
    ) {
        self.shootName = shootName
        self.generatedAt = generatedAt
        self.sourceCount = sourceCount
        self.keptCount = keptCount
        self.alternateCount = alternateCount
        self.hiddenCount = hiddenCount
        self.unusableCount = unusableCount
        self.pickCount = pickCount
        self.rejectCount = rejectCount
        self.confirmationCount = confirmationCount
        self.cameras = cameras
        self.tasteReady = tasteReady
        self.entries = entries
    }

    public var summaryLine: String {
        "\(keptCount) kept · \(alternateCount) similar · \(unusableCount) unusable · \(pickCount) favorites"
    }

    public func writeJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func writeMarkdown(to url: URL) throws {
        var lines = [
            "# Photocore cull — \(shootName)",
            "",
            summaryLine,
            "",
            "- Source photos: \(sourceCount)",
            "- Kept: \(keptCount)",
            "- Similar / alternates: \(alternateCount)",
            "- Hidden: \(hiddenCount)",
            "- Unusable: \(unusableCount)",
            "- Favorites (P): \(pickCount)",
            "- Rejects (X): \(rejectCount)",
            "- Close calls checked: \(confirmationCount)",
            "- Cameras: \(cameras.isEmpty ? "—" : cameras.joined(separator: ", "))",
            "- Taste memory: \(tasteReady ? "active" : "still learning")",
            "",
            "| File | Bucket | Flag | Stars | Why |",
            "| --- | --- | --- | --- | --- |"
        ]
        for entry in entries.prefix(500) {
            let why = entry.reasons.prefix(2).joined(separator: "; ").replacingOccurrences(of: "|", with: "/")
            lines.append("| \(entry.fileName) | \(entry.bucket) | \(entry.flag) | \(entry.stars) | \(why) |")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
