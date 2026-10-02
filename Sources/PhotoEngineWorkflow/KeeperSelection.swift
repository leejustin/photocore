import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// The phone app's working set of keepers: the cull's picks, edited by swipes.
/// Kept separate from the Mac app's review flags so the consumer flow stays a
/// single yes-or-no per photo.
public struct KeeperSelection: Sendable, Equatable {
    public private(set) var keepers: Set<PhotoID>
    public private(set) var resolvedMoments: Set<String>

    public init(result: PipelineResult) {
        let kept = result.shortlist.decisions.filter { $0.bucket == .selected || $0.bucket == .protected }.map(\.photoID)
        keepers = Set(kept)
        resolvedMoments = []
    }

    public init(keepers: Set<PhotoID>) {
        self.keepers = keepers
        resolvedMoments = []
    }

    /// Applies one swipe. Accept keeps the suggestion, use keeps one alternative,
    /// drop keeps none of the moment's frames.
    public mutating func apply(_ action: ConfirmationAction, to moment: ConfirmationMoment) {
        let frames = Set(moment.candidateIDs).union([moment.suggestedID])
        keepers.subtract(frames)
        switch action {
        case .accept:
            keepers.insert(moment.suggestedID)
        case .use(let id):
            keepers.insert(frames.contains(id) ? id : moment.suggestedID)
        case .drop:
            break
        }
        resolvedMoments.insert(moment.id)
    }

    public mutating func toggle(_ id: PhotoID) {
        if keepers.contains(id) { keepers.remove(id) } else { keepers.insert(id) }
    }

    /// Keepers in capture order, the order a trip is told in.
    public func ordered(in result: PipelineResult) -> [AnalyzedPhoto] {
        result.analyzed
            .filter { keepers.contains($0.id) }
            .sorted { ($0.asset.metadata.captureDate ?? .distantPast, $0.asset.relativePath) < ($1.asset.metadata.captureDate ?? .distantPast, $1.asset.relativePath) }
    }
}
