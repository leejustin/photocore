import Foundation

/// What a book has been bought with, and what each plan allows. One source of
/// truth for the server, which enforces it, and the app and web pages, which
/// explain it. See `outputs/business-model.md`.
///
/// Free to make, pay to keep, print to own:
/// - Free: every book. Up to 15 friends with 150 photos each, the Book style, a
///   "Made free with Bound" footer, online for 90 days.
/// - Trip Pass ($4.99 once): keeps one book for good. Anyone in the book can
///   buy it, not only the person who made it. Both styles, editing, the
///   Instagram set, everyone's full-size photos to download, no footer.
/// - Event Pass ($39 once): a wedding or big party. Up to 100 friends with 300
///   photos each, kept for good from the start.
/// - Yearly ($24.99 a year): every book you make is kept, up to 12 a year,
///   while subscribed and a year after. Offered only to people who already
///   bought two Trip Passes in a year.
public enum Plan: String, Codable, Sendable, CaseIterable {
    case free
    /// Stored as "plus" so books made before the rename keep their plan.
    case plus
    case tripPass
    case eventPass

    public var displayName: String {
        switch self {
        case .free: "Free"
        case .plus: "Yearly"
        case .tripPass: "Trip Pass"
        case .eventPass: "Event Pass"
        }
    }

    public var limits: PlanLimits {
        switch self {
        case .free:
            PlanLimits(friends: 15, photosPerFriend: 150, styles: [.book], branded: true, instagram: false, editing: false, download: false)
        case .plus, .tripPass:
            PlanLimits(friends: 25, photosPerFriend: 150, styles: BookTheme.allCases, branded: false, instagram: true, editing: true, download: true)
        case .eventPass:
            PlanLimits(friends: 100, photosPerFriend: 300, styles: BookTheme.allCases, branded: false, instagram: true, editing: true, download: true)
        }
    }

    /// Paid plans rank above free; a book never moves to a lower plan.
    public var rank: Int {
        switch self {
        case .free: 0
        case .plus: 1
        case .tripPass: 1
        case .eventPass: 2
        }
    }

    /// Whether the book stays up for good once this plan is on it.
    public var keepsForGood: Bool { self == .tripPass || self == .eventPass }
}

public struct PlanLimits: Codable, Sendable, Equatable {
    /// People who can join through the invite link.
    public var friends: Int
    /// Photos one friend can add.
    public var photosPerFriend: Int
    public var styles: [BookTheme]
    /// A "Made free with Bound" footer with a link to make your own.
    public var branded: Bool
    public var instagram: Bool
    /// The person who made the book can fix the title, diary and captions.
    public var editing: Bool
    /// Everyone's full-size photos in the book, as one download.
    public var download: Bool

    /// Photos all friends together can add.
    public var friendPhotos: Int { friends * photosPerFriend }

    public init(friends: Int, photosPerFriend: Int, styles: [BookTheme], branded: Bool, instagram: Bool, editing: Bool, download: Bool) {
        self.friends = friends
        self.photosPerFriend = photosPerFriend
        self.styles = styles
        self.branded = branded
        self.instagram = instagram
        self.editing = editing
        self.download = download
    }

    public func allows(_ theme: BookTheme) -> Bool { styles.contains(theme) }

    enum CodingKeys: String, CodingKey {
        case friends, photosPerFriend, styles, branded, instagram, editing, download, friendPhotos
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        friends = try container.decode(Int.self, forKey: .friends)
        styles = try container.decode([BookTheme].self, forKey: .styles)
        branded = try container.decode(Bool.self, forKey: .branded)
        instagram = try container.decode(Bool.self, forKey: .instagram)
        editing = try container.decode(Bool.self, forKey: .editing)
        download = try container.decodeIfPresent(Bool.self, forKey: .download) ?? editing
        // Older servers sent only a total for all friends.
        if let each = try container.decodeIfPresent(Int.self, forKey: .photosPerFriend) {
            photosPerFriend = each
        } else {
            let total = try container.decodeIfPresent(Int.self, forKey: .friendPhotos) ?? 150 * max(friends, 1)
            photosPerFriend = max(1, total / max(friends, 1))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(friends, forKey: .friends)
        try container.encode(photosPerFriend, forKey: .photosPerFriend)
        try container.encode(friendPhotos, forKey: .friendPhotos)
        try container.encode(styles, forKey: .styles)
        try container.encode(branded, forKey: .branded)
        try container.encode(instagram, forKey: .instagram)
        try container.encode(editing, forKey: .editing)
        try container.encode(download, forKey: .download)
    }
}

/// The App Store products behind the paid plans. The identifiers predate the
/// Bound name and stay as they are, since App Store product IDs never change.
public enum PlanProduct: String, CaseIterable, Sendable {
    case plusYearly = "com.photocore.trip.plus.yearly"
    case tripPass = "com.photocore.trip.pass.trip"
    case eventPass = "com.photocore.trip.pass.event"

    public static let subscriptionGroupName = "Bound Yearly"

    public var plan: Plan {
        switch self {
        case .plusYearly: .plus
        case .tripPass: .tripPass
        case .eventPass: .eventPass
        }
    }

    /// Passes are spent on one book; Yearly renews.
    public var isPass: Bool { plan == .tripPass || plan == .eventPass }
}

/// Prices for purchases made on the web (Stripe), in US cents. The App Store
/// sets its own local prices for the same products.
public enum WebPrice {
    public static let tripPass = 499
    public static let eventPass = 3_900

    public static func cents(for plan: Plan) -> Int? {
        switch plan {
        case .tripPass: tripPass
        case .eventPass: eventPass
        case .free, .plus: nil
        }
    }
}

/// Printed copies anyone in a book can order.
public enum PrintProduct: String, Codable, Sendable, CaseIterable {
    case softcover
    case hardcover

    public var displayName: String {
        switch self {
        case .softcover: "Softcover book"
        case .hardcover: "Hardcover book"
        }
    }

    /// The price with standard shipping, in US cents.
    public var cents: Int {
        switch self {
        case .softcover: 2_900
        case .hardcover: 4_900
        }
    }
}

/// The rules that depend on time and counts rather than on the plan alone.
public enum PlanPolicy {
    public static let plusBooksPerYear = 12
    /// How long a free book stays up after it's first finished.
    public static let freeHosting: TimeInterval = 90 * 24 * 3600
    /// How long a Yearly book stays up after the subscription ends.
    public static let plusGrace: TimeInterval = 365 * 24 * 3600
    /// Reminders before a free book goes offline, as time left.
    public static let reminders: [TimeInterval] = [7 * 24 * 3600, 24 * 3600]
    /// How long an offline book's photos are kept so someone can still keep it.
    public static let offlineGrace: TimeInterval = 30 * 24 * 3600
    /// Trip Passes bought in a year before Yearly is offered.
    public static let passesBeforeYearly = 2

    /// When a book stops being served, or nil for never.
    public static func hostedUntil(plan: Plan, firstFinished: Date, subscriptionExpires: Date?) -> Date? {
        switch plan {
        case .free: firstFinished.addingTimeInterval(freeHosting)
        case .plus: (subscriptionExpires ?? firstFinished).addingTimeInterval(plusGrace)
        case .tripPass, .eventPass: nil
        }
    }

    /// Books started on one Yearly subscription in the year before `now`.
    public static func plusBooksUsed(_ starts: [Date], now: Date = Date()) -> Int {
        starts.filter { now.timeIntervalSince($0) < 365 * 24 * 3600 }.count
    }

    /// Whether to offer Yearly to someone who bought passes on these dates.
    public static func offersYearly(passPurchases: [Date], now: Date = Date()) -> Bool {
        passPurchases.filter { now.timeIntervalSince($0) < 365 * 24 * 3600 }.count >= passesBeforeYearly
    }

    /// The reminder due for a free book, if one hasn't been sent: the index
    /// into `reminders` of the latest threshold that has been crossed.
    public static func reminderDue(hostedUntil: Date, sent: Set<Int>, now: Date = Date()) -> Int? {
        let left = hostedUntil.timeIntervalSince(now)
        guard left > 0 else { return nil }
        let crossed = reminders.indices.filter { left <= reminders[$0] }
        guard let latest = crossed.last, !sent.contains(latest) else { return nil }
        return latest
    }

    /// Whole days left before a date, rounded up, never below zero.
    public static func daysLeft(until date: Date, now: Date = Date()) -> Int {
        max(0, Int((date.timeIntervalSince(now) / 86_400).rounded(.up)))
    }
}
