import CoreGraphics
import Foundation
import PhotoEngineApple
import Testing

/// "Photos of you": taps grow to close faces, survive a refinish, and the
/// picker is stable.
struct FaceIndexTests {
    /// Embeddings are one number; distance is the gap between them.
    struct LineEmbedder: FaceEmbedder {
        var kind: String { "line" }
        var matchThreshold: Double { 0.5 }
        func embed(_ crop: CGImage) throws -> Data? { nil }
        func distance(_ a: Data, _ b: Data) -> Double? {
            guard let x = Double(String(decoding: a, as: UTF8.self)), let y = Double(String(decoding: b, as: UTF8.self)) else { return nil }
            return abs(x - y)
        }
    }

    func face(_ id: String, _ value: Double, photo: String, quality: Double = 0.5, group: Int = 0) -> IndexedFace {
        IndexedFace(id: id, photo: photo, quality: quality, embedding: Data(String(value).utf8), group: group)
    }

    @Test func tapsGrowToCloseFacesOnly() {
        let index = FaceIndex(kind: "line", faces: [
            face("a1", 1.0, photo: "p1"), face("a2", 1.3, photo: "p2"), face("a3", 1.45, photo: "p3"),
            face("b1", 3.0, photo: "p1"), face("b2", 3.2, photo: "p4")
        ])
        let embedder = LineEmbedder()
        #expect(index.matches(["a1"], embedder: embedder) == ["a1", "a2", "a3"])
        #expect(index.matches(["b2"], embedder: embedder) == ["b1", "b2"])
        // Taps are stored as embeddings, so they still work after a refinish
        // gives every face a new id.
        let refinished = FaceIndex(kind: "line", faces: [face("x1", 1.02, photo: "p1"), face("x2", 3.1, photo: "p4")])
        #expect(refinished.matches(embeddings: [Data("1.0".utf8)], embedder: embedder) == ["x1"])
        #expect(refinished.tapped(embeddings: [Data("1.0".utf8)], embedder: embedder) == ["x1"])
        // An index made by another embedder is never compared.
        let other = FaceIndex(kind: "vision", faces: index.faces)
        #expect(other.matches(embeddings: [Data("1.0".utf8)], embedder: embedder).isEmpty)
    }

    @Test func pickerShowsEachGroupOnceThenTheRestInAStableOrder() {
        let index = FaceIndex(kind: "line", faces: [
            face("c", 1, photo: "p", quality: 0.9, group: 0), face("d", 1, photo: "p", quality: 0.4, group: 0),
            face("e", 5, photo: "p", quality: 0.7, group: 1), face("f", 9, photo: "p", quality: 0.7, group: 2)
        ])
        let order = index.pickerOrder().map(\.id)
        #expect(order == ["c", "e", "f", "d"])
        for _ in 0..<20 { #expect(index.pickerOrder().map(\.id) == order) }
    }
}
