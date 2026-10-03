import Foundation
import Logging
import PhotoEngineWorkflow
import ServiceLifecycle

/// The slow clock behind every book: reminders before a free book goes
/// offline, deleting an offline book's photos once nobody kept it, and the
/// work other parts of the server hand it (see `extraWork`).
actor BookLifecycle {
    struct Report: Codable, Sendable, Equatable {
        var reminders = 0
        var purged = 0
        var other: [String: Int] = [:]
    }

    let trips: TripStore
    let mailer: any Mailer
    let address: PublicAddress
    var publicBase: String { address.base }
    private let logger = Logger(label: "Bound.lifecycle")
    /// More work to run on each tick, added by other parts of the server
    /// (nightly refinish, deleting unpicked photos). Each returns a count.
    private var extraWork: [(String, @Sendable (Date) async -> Int)] = []

    init(trips: TripStore, mailer: any Mailer, address: PublicAddress) {
        self.trips = trips
        self.mailer = mailer
        self.address = address
    }

    func add(_ name: String, _ work: @escaping @Sendable (Date) async -> Int) {
        extraWork.append((name, work))
    }

    func bookURL(_ record: TripRecord) -> String { publicBase + TripPaths.book(record.slug) }
    func unsubscribeURL(_ token: String) -> String { publicBase + "/u/" + token }

    /// Sends to everyone on the book's list, logging failures instead of throwing.
    func send(_ make: (Recipient) -> Mail, to recipients: [Recipient]) async -> Int {
        var sent = 0
        for recipient in recipients {
            do {
                try await mailer.send(make(recipient))
                sent += 1
            } catch {
                logger.error("Email failed", metadata: ["error": "\(error)"])
            }
        }
        return sent
    }

    @discardableResult
    func tick(now: Date = Date()) async -> Report {
        var report = Report()
        for record in await trips.allRecords() {
            guard record.currentPlan == .free, record.finishedAt != nil, record.purgedAt == nil, let until = record.hostedUntil else { continue }
            if now > until.addingTimeInterval(PlanPolicy.offlineGrace) {
                do {
                    try await trips.purge(record.id, now: now)
                    report.purged += 1
                } catch {
                    logger.error("Purge failed", metadata: ["trip": "\(record.id)", "error": "\(error)"])
                }
                continue
            }
            guard let due = PlanPolicy.reminderDue(hostedUntil: until, sent: Set(record.remindersSent ?? []), now: now) else { continue }
            let book = try? TripBook.load(from: await trips.bookFolder(record.id))
            let title = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? book?.title ?? "your trip"
            let days = PlanPolicy.daysLeft(until: until, now: now)
            let url = bookURL(record)
            report.reminders += await send({ recipient in
                MailTemplates.reminder(to: recipient.email, title: title, credit: book?.creditLine, until: until, daysLeft: days, bookURL: url, unsubscribe: unsubscribeURL(recipient.unsubscribeToken))
            }, to: await trips.recipients(record.id))
            // Earlier reminders count as sent too, so a late tick sends one email, not two.
            try? await trips.update(record.id) { $0.remindersSent = Array(0...due) }
        }
        for (name, work) in extraWork {
            let count = await work(now)
            if count > 0 { report.other[name, default: 0] += count }
        }
        return report
    }
}

/// Runs the lifecycle every few minutes for as long as the server runs.
struct LifecycleService: Service {
    let lifecycle: BookLifecycle
    var interval: Duration = .seconds(15 * 60)

    func run() async throws {
        try await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                await lifecycle.tick()
                try await Task.sleep(for: interval)
            }
        }
    }
}

/// The server's public base for absolute links: `PHOTOCORE_PUBLIC_URL` when
/// set, otherwise the loopback address it's listening on.
final class PublicAddress: @unchecked Sendable {
    private let lock = NSLock()
    private let configured: String?
    private var port = 8787

    init(_ configured: String?) { self.configured = configured }

    func listening(on port: Int) { lock.withLock { self.port = port } }

    var base: String { configured ?? lock.withLock { "http://127.0.0.1:\(port)" } }
}
