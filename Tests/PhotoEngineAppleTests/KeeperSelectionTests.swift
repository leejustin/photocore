import Foundation
import PhotoEngineCore
import PhotoEngineWorkflow
import Testing

@Suite("Keeper swipes")
struct KeeperSelectionTests {
    let a = PhotoID(), b = PhotoID(), c = PhotoID(), d = PhotoID()

    func moment() -> ConfirmationMoment {
        ConfirmationMoment(id: "m1", suggestedID: a, candidateIDs: [a, b, c], reason: "close", margin: 0.01)
    }

    @Test("accept keeps only the suggestion")
    func accept() {
        var selection = KeeperSelection(keepers: [a, b, d])
        selection.apply(.accept, to: moment())
        #expect(selection.keepers == [a, d])
        #expect(selection.resolvedMoments == ["m1"])
    }

    @Test("use swaps in the alternative")
    func use() {
        var selection = KeeperSelection(keepers: [a, d])
        selection.apply(.use(c), to: moment())
        #expect(selection.keepers == [c, d])
    }

    @Test("drop removes the whole moment, toggle restores one")
    func drop() {
        var selection = KeeperSelection(keepers: [a, b, d])
        selection.apply(.drop, to: moment())
        #expect(selection.keepers == [d])
        selection.toggle(b)
        #expect(selection.keepers == [b, d])
    }

    @Test("an unknown alternative falls back to the suggestion")
    func unknownUse() {
        var selection = KeeperSelection(keepers: [])
        selection.apply(.use(d), to: moment())
        #expect(selection.keepers == [a])
    }
}
