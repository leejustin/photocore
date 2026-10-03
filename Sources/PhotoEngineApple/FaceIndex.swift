import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import PhotoEngineCore
import UniformTypeIdentifiers
import Vision

/// "Photos of you" without recognizing anyone. Every face in a finished book
/// gets an aligned crop and an embedding. A friend taps their own face once or
/// twice; faces close to the ones they tapped are theirs. Nothing is matched
/// against a name, a selfie or anything outside the one book, and the index is
/// deleted with the book.
///
/// Measured on 300 frames of a real event shoot (201 faces, 2026-10-03): with
/// Vision feature prints of aligned crops, faces of different people in the
/// same photo sit at p5 0.59, p50 0.84; grouping under 0.5 was almost always
/// one person, but split most people into several groups. So Vision is
/// precise and incomplete, which tapping more faces makes up for. A proper
/// face-embedding Core ML model (`PHOTOCORE_FACE_MODEL`) finds more.
public protocol FaceEmbedder: Sendable {
    /// Stored with the index, so a book is never compared across embedders.
    var kind: String { get }
    /// Faces closer than this to a tapped face are the same person.
    var matchThreshold: Double { get }
    func embed(_ crop: CGImage) throws -> Data?
    func distance(_ a: Data, _ b: Data) -> Double?
}

/// Vision's revision-2 feature print of the aligned face crop.
public struct VisionFaceEmbedder: FaceEmbedder {
    public var kind: String { "vision-featureprint-2" }
    public var matchThreshold: Double

    public init(matchThreshold: Double = 0.5) {
        self.matchThreshold = matchThreshold
    }

    public func embed(_ crop: CGImage) throws -> Data? { try AppleVisualDistance.featurePrintData(for: crop) }

    public func distance(_ a: Data, _ b: Data) -> Double? { AppleVisualDistance.distance(a, b) }
}

/// A face-embedding Core ML model: one image input, one vector output, compared
/// by cosine distance. Bring a model whose license allows the use; none is
/// included.
public struct CoreMLFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    let model: MLModel
    let inputName: String
    let outputName: String
    let side: Int
    public let kind: String
    public var matchThreshold: Double

    public init(modelURL: URL, matchThreshold: Double = 0.6) throws {
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        model = try MLModel(contentsOf: compiled)
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let output = description.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) else {
            throw FaceIndexError.unsupportedModel
        }
        inputName = input.key
        outputName = output.key
        side = input.value.imageConstraint?.pixelsWide ?? 112
        kind = "coreml-" + modelURL.deletingPathExtension().lastPathComponent
        self.matchThreshold = matchThreshold
    }

    public func embed(_ crop: CGImage) throws -> Data? {
        let value = try MLFeatureValue(cgImage: crop, pixelsWide: side, pixelsHigh: side, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: value]))
        guard let array = result.featureValue(for: outputName)?.multiArrayValue else { return nil }
        var vector = (0..<array.count).map { Float(truncating: array[$0]) }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { vector = vector.map { $0 / norm } }
        return vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public func distance(_ a: Data, _ b: Data) -> Double? {
        guard a.count == b.count, a.count % 4 == 0 else { return nil }
        let x = a.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let y = b.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return 1 - Double(zip(x, y).reduce(0) { $0 + $1.0 * $1.1 })
    }
}

public enum FaceIndexError: Error {
    case unsupportedModel
}

public struct IndexedFace: Codable, Sendable, Equatable {
    public var id: String
    /// The book photo the face is in.
    public var photo: String
    public var quality: Double
    public var embedding: Data
    /// Faces in one group look like the same person; groups order the picker.
    public var group: Int

    public init(id: String, photo: String, quality: Double, embedding: Data, group: Int) {
        self.id = id
        self.photo = photo
        self.quality = quality
        self.embedding = embedding
        self.group = group
    }
}

public struct FaceIndex: Codable, Sendable {
    public var kind: String
    public var faces: [IndexedFace]

    public init(kind: String, faces: [IndexedFace]) {
        self.kind = kind
        self.faces = faces
    }

    public static let fileName = "index.json"

    public static func load(from folder: URL) -> FaceIndex? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(FaceIndex.self, from: data)
    }

    public func save(to folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Faces of the person who tapped `chosen`: the tapped faces and every face
    /// close to one of them, in the same index.
    public func matches(_ chosen: Set<String>, embedder: any FaceEmbedder) -> Set<String> {
        guard embedder.kind == kind else { return chosen.intersection(faces.map(\.id)) }
        let seeds = faces.filter { chosen.contains($0.id) }
        var result = Set(seeds.map(\.id))
        for face in faces where !result.contains(face.id) {
            if seeds.contains(where: { embedder.distance($0.embedding, face.embedding).map { $0 < embedder.matchThreshold } ?? false }) {
                result.insert(face.id)
            }
        }
        return result
    }

    /// Faces near any of these embeddings (a person's taps, kept across
    /// refinishes, when face ids change).
    public func matches(embeddings: [Data], embedder: any FaceEmbedder) -> Set<String> {
        guard embedder.kind == kind, !embeddings.isEmpty else { return [] }
        return Set(faces.filter { face in
            embeddings.contains { embedder.distance($0, face.embedding).map { $0 < embedder.matchThreshold } ?? false }
        }.map(\.id))
    }

    /// Faces that are one of these taps (the same crop, give or take a refinish).
    public func tapped(embeddings: [Data], embedder: any FaceEmbedder, within: Double = 0.12) -> Set<String> {
        guard embedder.kind == kind else { return [] }
        return Set(faces.filter { face in embeddings.contains { embedder.distance($0, face.embedding).map { $0 < within } ?? false } }.map(\.id))
    }

    /// Faces for the picker: the best face of each group first, biggest groups
    /// first, then the rest.
    public func pickerOrder(limit: Int = 120) -> [IndexedFace] {
        // Stable from one request to the next: ties break by quality, then id.
        func before(_ a: IndexedFace, _ b: IndexedFace) -> Bool { a.quality != b.quality ? a.quality > b.quality : a.id < b.id }
        let groups = Dictionary(grouping: faces, by: \.group).values.map { $0.sorted(by: before) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : before($0[0], $1[0]) }
        var ordered = groups.compactMap(\.first)
        let leaders = Set(ordered.map(\.id))
        ordered += faces.filter { !leaders.contains($0.id) }.sorted(by: before)
        return Array(ordered.prefix(limit))
    }
}

public enum FaceIndexer {
    /// The embedder this process uses: a Core ML model when
    /// `PHOTOCORE_FACE_MODEL` names one, otherwise Vision.
    public static func defaultEmbedder(environment: [String: String] = ProcessInfo.processInfo.environment) -> any FaceEmbedder {
        if let path = environment["PHOTOCORE_FACE_MODEL"], !path.isEmpty,
           let model = try? CoreMLFaceEmbedder(modelURL: URL(fileURLWithPath: path), matchThreshold: Double(environment["PHOTOCORE_FACE_THRESHOLD"] ?? "") ?? 0.6) {
            return model
        }
        return VisionFaceEmbedder(matchThreshold: Double(environment["PHOTOCORE_FACE_THRESHOLD"] ?? "") ?? 0.5)
    }

    /// Finds, crops and embeds every clear face in the photos, writing a
    /// 160-pixel crop of each to `crops` as `<face id>.jpg`.
    public static func index(photos: [(id: String, url: URL)], crops: URL, embedder: any FaceEmbedder, minimumFace: CGFloat = 60) throws -> FaceIndex {
        try FileManager.default.createDirectory(at: crops, withIntermediateDirectories: true)
        let context = CIContext(options: [.cacheIntermediates: false])
        var faces: [IndexedFace] = []
        for photo in photos {
            guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 2048
                  ] as CFDictionary) else { continue }
            let landmarks = VNDetectFaceLandmarksRequest()
            try? VNImageRequestHandler(cgImage: image).perform([landmarks])
            let found = (landmarks.results ?? []).filter { CGFloat($0.boundingBox.width) * CGFloat(image.width) >= minimumFace }
            guard !found.isEmpty else { continue }
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = found
            try? VNImageRequestHandler(cgImage: image).perform([quality])
            let scores = Dictionary((quality.results ?? []).map { ($0.uuid, Double($0.faceCaptureQuality ?? 0)) }, uniquingKeysWith: max)
            for face in found {
                guard let crop = alignedCrop(image, face, context: context), let embedding = try embedder.embed(crop) else { continue }
                let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
                try writeJPEG(crop, side: 160, to: crops.appendingPathComponent("\(id).jpg"))
                faces.append(IndexedFace(id: String(id), photo: photo.id, quality: scores[face.uuid] ?? 0, embedding: embedding, group: -1))
            }
        }
        // Leader grouping: best faces first, each joins the first group whose
        // leader is close enough, or starts a new one.
        var leaders: [IndexedFace] = []
        for index in faces.indices.sorted(by: { faces[$0].quality > faces[$1].quality }) {
            if let group = leaders.firstIndex(where: { embedder.distance($0.embedding, faces[index].embedding).map { $0 < embedder.matchThreshold } ?? false }) {
                faces[index].group = group
            } else {
                faces[index].group = leaders.count
                leaders.append(faces[index])
            }
        }
        return FaceIndex(kind: embedder.kind, faces: faces)
    }

    /// The face turned level by its eyes and cropped square with some margin.
    static func alignedCrop(_ image: CGImage, _ face: VNFaceObservation, context: CIContext) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let box = CGRect(x: face.boundingBox.minX * w, y: face.boundingBox.minY * h, width: face.boundingBox.width * w, height: face.boundingBox.height * h)
        var angle: CGFloat = 0
        if let marks = face.landmarks, let left = marks.leftEye?.normalizedPoints, let right = marks.rightEye?.normalizedPoints, !left.isEmpty, !right.isEmpty {
            func center(_ points: [CGPoint]) -> CGPoint {
                CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            }
            let a = center(left), b = center(right)
            angle = atan2((b.y - a.y) * box.height, (b.x - a.x) * box.width)
        } else if let roll = face.roll?.doubleValue {
            angle = CGFloat(roll)
        }
        let side = max(box.width, box.height) * 1.25
        let moved = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: -box.midX, y: -box.midY).concatenating(CGAffineTransform(rotationAngle: -angle)))
            .cropped(to: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: side / 2, y: side / 2))
            .transformed(by: CGAffineTransform(scaleX: 224 / side, y: 224 / side))
        return context.createCGImage(moved, from: CGRect(x: 0, y: 0, width: 224, height: 224))
    }

    static func writeJPEG(_ image: CGImage, side: Int, to url: URL) throws {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = context?.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
