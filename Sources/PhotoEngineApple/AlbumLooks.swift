import CoreImage
import Foundation

import PhotoEngineCore

public struct AlbumLook: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: Kind
    public var style: StylePreset?
    public var intensity: Double
    public var temperature: Double
    public var tint: Double
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var highlights: Double
    public var shadows: Double
    public var clarity: Double
    public var sharpening: Double
    public var straighten: Double
    public var autoStraighten: Bool
    public var lutFileName: String?

    public enum Kind: String, Codable, Sendable {
        case builtin
        case lut
        case xmp
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind,
        style: StylePreset? = nil,
        intensity: Double = 0.65,
        temperature: Double = 0,
        tint: Double = 0,
        exposure: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        clarity: Double = 0,
        sharpening: Double = 0,
        straighten: Double = 0,
        autoStraighten: Bool = false,
        lutFileName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.style = style
        self.intensity = intensity
        self.temperature = temperature
        self.tint = tint
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.highlights = highlights
        self.shadows = shadows
        self.clarity = clarity
        self.sharpening = sharpening
        self.straighten = straighten
        self.autoStraighten = autoStraighten
        self.lutFileName = lutFileName
    }

    public static var builtins: [AlbumLook] {
        StylePreset.allCases.map {
            AlbumLook(id: "builtin.\($0.rawValue)", name: $0.displayName, kind: .builtin, style: $0)
        }
    }

    public func recipe(for photo: AnalyzedPhoto, horizonDegrees: Double? = nil) -> EditRecipe {
        let base: EditRecipe
        if let style {
            base = ApplePhotoRenderer.recipe(for: photo, style: style, intensity: intensity)
        } else {
            base = EditRecipe(style: .natural, styleIntensity: intensity, autoEnhance: true)
        }
        var recipe = base
        recipe.temperature = min(max(base.temperature + temperature, -1), 1)
        recipe.tint = min(max(base.tint + tint, -1), 1)
        recipe.exposure += exposure
        recipe.contrast += contrast
        recipe.saturation += saturation
        recipe.highlights += highlights
        recipe.shadows += shadows
        recipe.clarity += clarity
        recipe.sharpening = max(0, recipe.sharpening + sharpening)
        if autoStraighten, let horizonDegrees {
            recipe.straighten = horizonDegrees
        } else {
            recipe.straighten = straighten
        }
        recipe.albumLookID = id
        return recipe
    }
}

public final class AlbumLookLibrary: @unchecked Sendable {
    public static let shared = AlbumLookLibrary()

    private let root: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var cached: [AlbumLook]?

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = appSupport.appendingPathComponent("Photocore/looks", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.root.appendingPathComponent("luts", isDirectory: true), withIntermediateDirectories: true)
    }

    public func allLooks() -> [AlbumLook] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return AlbumLook.builtins + cached }
        let imported = loadImported()
        cached = imported
        return AlbumLook.builtins + imported
    }

    public func look(id: String?) -> AlbumLook? {
        guard let id else { return nil }
        return allLooks().first { $0.id == id }
    }

    public func importCubeLUT(from url: URL, name: String? = nil) throws -> AlbumLook {
        let data = try Data(contentsOf: url)
        _ = try CubeLUTParser.parse(data) // validate
        let lookID = UUID().uuidString
        let fileName = "\(lookID).cube"
        let destination = root.appendingPathComponent("luts", isDirectory: true).appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        let look = AlbumLook(
            id: lookID,
            name: name ?? url.deletingPathExtension().lastPathComponent,
            kind: .lut,
            intensity: 1,
            lutFileName: fileName
        )
        try save(look)
        return look
    }

    public func importXMPPreset(from url: URL, name: String? = nil) throws -> AlbumLook {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = XMPDevelopPresetParser.parse(text)
        let look = AlbumLook(
            id: UUID().uuidString,
            name: name ?? url.deletingPathExtension().lastPathComponent,
            kind: .xmp,
            intensity: 1,
            temperature: parsed.temperature,
            tint: parsed.tint,
            exposure: parsed.exposure,
            contrast: parsed.contrast,
            saturation: parsed.saturation,
            highlights: parsed.highlights,
            shadows: parsed.shadows,
            clarity: parsed.clarity,
            sharpening: parsed.sharpening
        )
        try save(look)
        return look
    }

    public func lutData(for look: AlbumLook) throws -> Data? {
        guard let fileName = look.lutFileName else { return nil }
        let url = root.appendingPathComponent("luts", isDirectory: true).appendingPathComponent(fileName)
        return try Data(contentsOf: url)
    }

    public func colorCubeFilter(for look: AlbumLook) throws -> CIFilter? {
        guard look.kind == .lut, let data = try lutData(for: look) else { return nil }
        let cube = try CubeLUTParser.parse(data)
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(cube.dimension, forKey: "inputCubeDimension")
        filter?.setValue(cube.rgbaData, forKey: "inputCubeData")
        return filter
    }

    private func save(_ look: AlbumLook) throws {
        lock.lock()
        defer { lock.unlock() }
        var imported = loadImported()
        imported.removeAll { $0.id == look.id }
        imported.append(look)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(imported).write(to: catalogURL, options: .atomic)
        cached = imported
    }

    private var catalogURL: URL {
        root.appendingPathComponent("catalog.json")
    }

    private func loadImported() -> [AlbumLook] {
        guard let data = try? Data(contentsOf: catalogURL) else { return [] }
        return (try? JSONDecoder().decode([AlbumLook].self, from: data)) ?? []
    }
}

public struct CubeLUT {
    public let dimension: Int
    public let rgbaData: Data
}

public enum CubeLUTParser {
    public static func parse(_ data: Data) throws -> CubeLUT {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw PhotoEngineError.invalidArgument("LUT file was not readable text")
        }
        var dimension = 0
        var values: [Float] = []
        values.reserveCapacity(32 * 32 * 32 * 4)
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") || upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") {
                continue
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                guard let last = parts.last, let size = Int(last), size > 1, size <= 128 else {
                    throw PhotoEngineError.invalidArgument("Invalid LUT_3D_SIZE")
                }
                dimension = size
                continue
            }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
            guard parts.count >= 3 else { continue }
            values.append(parts[0])
            values.append(parts[1])
            values.append(parts[2])
            values.append(1)
        }
        guard dimension > 1 else { throw PhotoEngineError.invalidArgument("LUT_3D_SIZE missing") }
        let expected = dimension * dimension * dimension * 4
        guard values.count == expected else {
            throw PhotoEngineError.invalidArgument("LUT data size mismatch (\(values.count) floats, expected \(expected))")
        }
        let rgba = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(dimension: dimension, rgbaData: rgba)
    }
}

public struct XMPDevelopValues: Sendable {
    public var temperature: Double = 0
    public var tint: Double = 0
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var saturation: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var clarity: Double = 0
    public var sharpening: Double = 0
}

public enum XMPDevelopPresetParser {
    public static func parse(_ xml: String) -> XMPDevelopValues {
        var values = XMPDevelopValues()
        // Map common Lightroom crs: keys into Photocore's compact -1...1 / EV-ish space.
        if let temperature = number(in: xml, keys: ["crs:Temperature", "Temperature"]) {
            // 2000...50000 → roughly -1...1 around 5500
            values.temperature = min(max((temperature - 5500) / 3500, -1), 1)
        }
        if let tint = number(in: xml, keys: ["crs:Tint", "Tint"]) {
            values.tint = min(max(tint / 50, -1), 1)
        }
        if let exposure = number(in: xml, keys: ["crs:Exposure2012", "crs:Exposure", "Exposure2012"]) {
            values.exposure = min(max(exposure / 2.5, -1), 1)
        }
        if let contrast = number(in: xml, keys: ["crs:Contrast2012", "crs:Contrast"]) {
            values.contrast = min(max(contrast / 100, -1), 1)
        }
        if let saturation = number(in: xml, keys: ["crs:Saturation", "crs:Vibrance"]) {
            values.saturation = min(max(saturation / 100, -1), 1)
        }
        if let highlights = number(in: xml, keys: ["crs:Highlights2012", "crs:Highlights"]) {
            values.highlights = min(max(highlights / 100, -1), 1)
        }
        if let shadows = number(in: xml, keys: ["crs:Shadows2012", "crs:Shadows"]) {
            values.shadows = min(max(shadows / 100, -1), 1)
        }
        if let clarity = number(in: xml, keys: ["crs:Clarity2012", "crs:Clarity"]) {
            values.clarity = min(max(clarity / 100, -1), 1)
        }
        if let sharpen = number(in: xml, keys: ["crs:SharpenAmount", "crs:Sharpness"]) {
            values.sharpening = min(max(sharpen / 150, 0), 1)
        }
        return values
    }

    private static func number(in xml: String, keys: [String]) -> Double? {
        for key in keys {
            let patterns = [
                #"\#(key)\s*=\s*"([-+0-9.]+)""#,
                #"<\#(key)>([-+0-9.]+)</"#
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                   let range = Range(match.range(at: 1), in: xml),
                   let value = Double(xml[range]) {
                    return value
                }
            }
        }
        return nil
    }
}
