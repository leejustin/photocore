import Foundation
import PDFKit
import PhotoEngineCore
import PhotoEngineWorkflow
import Testing

/// The pricing rules: what each plan allows, how long books stay up, Yearly's
/// book count, reminders, what a free book page shows, and the print PDF.
struct PlansTests {
    @Test func eachPlanAllowsWhatThePricingSays() {
        let free = Plan.free.limits
        #expect(free.friends == 15 && free.photosPerFriend == 150 && free.branded && !free.editing && !free.instagram && !free.download)
        #expect(free.allows(.book) && !free.allows(.snapshot))
        let pass = Plan.tripPass.limits
        #expect(pass.friends == 25 && !pass.branded && pass.editing && pass.instagram && pass.download && pass.allows(.snapshot))
        #expect(Plan.plus.limits == pass && Plan.plus.displayName == "Yearly")
        let event = Plan.eventPass.limits
        #expect(event.friends == 100 && event.photosPerFriend == 300 && event.friendPhotos == 30_000)
        #expect(Plan.eventPass.rank > Plan.tripPass.rank && Plan.tripPass.rank > Plan.free.rank)
        #expect(PlanProduct.allCases.filter(\.isPass).map(\.plan) == [.tripPass, .eventPass])
        #expect(WebPrice.cents(for: .tripPass) == 499 && WebPrice.cents(for: .eventPass) == 3_900 && WebPrice.cents(for: .free) == nil)
    }

    @Test func limitsReadWhatOlderServersSent() throws {
        let old = #"{"friends":25,"friendPhotos":500,"styles":["book","snapshot"],"branded":false,"instagram":true,"editing":true}"#
        let limits = try JSONDecoder().decode(PlanLimits.self, from: Data(old.utf8))
        #expect(limits.photosPerFriend == 20 && limits.download)
        let round = try JSONDecoder().decode(PlanLimits.self, from: JSONEncoder().encode(Plan.free.limits))
        #expect(round == Plan.free.limits)
    }

    @Test func remindersComeAWeekAndADayBefore() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        #expect(PlanPolicy.reminderDue(hostedUntil: end, sent: [], now: end.addingTimeInterval(-20 * day)) == nil)
        #expect(PlanPolicy.reminderDue(hostedUntil: end, sent: [], now: end.addingTimeInterval(-6 * day)) == 0)
        #expect(PlanPolicy.reminderDue(hostedUntil: end, sent: [0], now: end.addingTimeInterval(-6 * day)) == nil)
        #expect(PlanPolicy.reminderDue(hostedUntil: end, sent: [0], now: end.addingTimeInterval(-0.5 * day)) == 1)
        // A server that was down all week sends only the last one.
        #expect(PlanPolicy.reminderDue(hostedUntil: end, sent: [], now: end.addingTimeInterval(-0.5 * day)) == 1)
        #expect(PlanPolicy.reminderDue(hostedUntil: end, sent: [], now: end.addingTimeInterval(day)) == nil)
        #expect(PlanPolicy.daysLeft(until: end, now: end.addingTimeInterval(-6.2 * day)) == 7)
    }

    @Test func yearlyIsOfferedAfterTwoPassesInAYear() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        #expect(!PlanPolicy.offersYearly(passPurchases: [now.addingTimeInterval(-10 * day)], now: now))
        #expect(PlanPolicy.offersYearly(passPurchases: [now.addingTimeInterval(-10 * day), now.addingTimeInterval(-90 * day)], now: now))
        #expect(!PlanPolicy.offersYearly(passPurchases: [now.addingTimeInterval(-10 * day), now.addingTimeInterval(-400 * day)], now: now))
    }

    @Test func booksStayUpForTheRightTime() {
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        let year: TimeInterval = 365 * 24 * 3600
        #expect(PlanPolicy.hostedUntil(plan: .free, firstFinished: finished, subscriptionExpires: nil) == finished.addingTimeInterval(90 * 24 * 3600))
        let renews = finished.addingTimeInterval(40 * 24 * 3600)
        #expect(PlanPolicy.hostedUntil(plan: .plus, firstFinished: finished, subscriptionExpires: renews) == renews.addingTimeInterval(year))
        #expect(PlanPolicy.hostedUntil(plan: .tripPass, firstFinished: finished, subscriptionExpires: nil) == nil)
        #expect(PlanPolicy.hostedUntil(plan: .eventPass, firstFinished: finished, subscriptionExpires: nil) == nil)
    }

    @Test func plusCountsOnlyTheLastYearsBooks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 3600
        let starts = [now.addingTimeInterval(-10 * day), now.addingTimeInterval(-200 * day), now.addingTimeInterval(-400 * day)]
        #expect(PlanPolicy.plusBooksUsed(starts, now: now) == 2)
    }

    func book(photos: [BookPhoto]) -> TripBook {
        TripBook(title: "Lisbon", intro: "Three days by the river.", dateRange: "Oct 9 – 11, 2026", coverPhotoID: photos.first?.id, sections: [
            BookSection(id: "s1", heading: "Belém in the morning", dateLine: "Friday, Oct 9", place: "Belém, Lisbon", diary: "We walked along the river past the tower.", photos: photos)
        ], writer: "template", theme: .book)
    }

    @Test func freeBooksAreBrandedAndPaidBooksAreNot() {
        let page = book(photos: [BookPhoto(id: PhotoID(), fileName: "a.jpg")])
        let free = BookRenderer.html(page, options: .init(guestEndpoint: "/g", printInterestEndpoint: "/b/x/print-interest", footer: BookRenderer.Options.freeFooter, footerLink: "https://example.com"))
        #expect(free.contains(BookRenderer.Options.freeFooter))
        #expect(free.contains("href=\"https://example.com\""))
        #expect(free.contains("id=\"print-interest\""))
        #expect(free.contains("edit: null"))
        let paid = BookRenderer.html(page, options: .init(editEndpoint: "/b/x/edits", guestEndpoint: "/g", footer: ""))
        #expect(!paid.contains("<footer>"))
        #expect(!paid.contains("id=\"print-interest\""))
        #expect(paid.contains("\"/b/x/edits\""))
    }

    @Test func printPDFHasEveryPageAtPrintSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var photos: [BookPhoto] = []
        for i in 0..<5 {
            let portrait = i >= 3
            try SyntheticPhotos.writeJPEG(seed: i, to: folder.appendingPathComponent("photos/p\(i).jpg"), width: portrait ? 480 : 640, height: portrait ? 640 : 480)
            photos.append(BookPhoto(id: PhotoID(), fileName: "p\(i).jpg", caption: i == 1 ? "By the tower" : "", isPortrait: portrait, credit: i % 2 == 0 ? "Sam" : "Ana"))
        }
        var printable = book(photos: photos)
        printable.credit(Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.credit ?? "") }))
        let url = folder.appendingPathComponent("book.pdf")
        let report = try BookPrinter.pdf(book: printable, folder: folder, to: url)
        // Cover, intro, chapter opener; the cover photo is not repeated, so two
        // landscapes alone and the two portraits as a pair; closing page.
        #expect(report.pages == 1 + 1 + 1 + 2 + 1 + 1)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == report.pages)
        let page = try #require(document.page(at: 0))
        #expect(abs(page.bounds(for: .trimBox).width - 576) < 0.5)
        #expect(abs(page.bounds(for: .mediaBox).width - 594) < 0.5)
        #expect(document.string?.contains("Photos by Sam and Ana") == true)
    }

    /// Renders a real finished book to a PDF to look at, when asked:
    /// PHOTOCORE_PRINT_BOOK=<book folder> PHOTOCORE_PRINT_OUT=<file.pdf>.
    @Test func printARealBookWhenAsked() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PHOTOCORE_PRINT_BOOK"], let out = environment["PHOTOCORE_PRINT_OUT"] else { return }
        let folder = URL(fileURLWithPath: path)
        let book = BookEdits.load(from: folder).applied(to: try TripBook.load(from: folder))
        let report = try BookPrinter.pdf(book: book, folder: folder, to: URL(fileURLWithPath: out))
        #expect(report.photos > 0)
    }
}
