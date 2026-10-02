import Foundation

/// What an owner has paid for, and what each plan allows. One source of truth
/// for the server, which enforces it, and the app, which explains it.
///
/// - Free: on-device culling always; the first book per phone, with up to five
///   friends, the clean Book style and a Photocore footer.
/// - Plus ($2.99 a month or $24.99 a year): up to twelve books a year, 25
///   friends and 500 friend photos per book, both styles, the Instagram set,
///   editing, no branding. Books stay up while subscribed and a year after.
/// - Trip Pass ($4.99 once): one book with everything Plus gives it, kept for good.
/// - Event Pass ($29 once): one book for up to 100 guests, kept for good.
public enum Plan: String, Codable, Sendable, CaseIterable {
    case free
    case plus
    case tripPass
    case eventPass

    public var displayName: String {
        switch self {
        case .free: "Free"
        case .plus: "Plus"
        case .tripPass: "Trip Pass"
        case .eventPass: "Event Pass"
        }
    }

    public var limits: PlanLimits {
        switch self {
        case .free:
            PlanLimits(friends: 5, friendPhotos: 150, styles: [.book], branded: true, instagram: false, editing: false)
        case .plus, .tripPass:
            PlanLimits(friends: 25, friendPhotos: 500, styles: BookTheme.allCases, branded: false, instagram: true, editing: true)
        case .eventPass:
            PlanLimits(friends: 100, friendPhotos: 1_000, styles: BookTheme.allCases, branded: false, instagram: true, editing: true)
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
}

public struct PlanLimits: Codable, Sendable, Equatable {
    /// People who can join through the invite link.
    public var friends: Int
    /// Photos all friends together can add.
    public var friendPhotos: Int
    public var styles: [BookTheme]
    /// A "Made with Photocore" footer with a link to make your own.
    public var branded: Bool
    public var instagram: Bool
    /// The owner can fix the title, diary and captions on the page.
    public var editing: Bool

    public init(friends: Int, friendPhotos: Int, styles: [BookTheme], branded: Bool, instagram: Bool, editing: Bool) {
        self.friends = friends
        self.friendPhotos = friendPhotos
        self.styles = styles
        self.branded = branded
        self.instagram = instagram
        self.editing = editing
    }

    public func allows(_ theme: BookTheme) -> Bool { styles.contains(theme) }
}

/// The App Store products behind the paid plans.
public enum PlanProduct: String, CaseIterable, Sendable {
    case plusMonthly = "com.photocore.trip.plus.monthly"
    case plusYearly = "com.photocore.trip.plus.yearly"
    case tripPass = "com.photocore.trip.pass.trip"
    case eventPass = "com.photocore.trip.pass.event"

    public static let subscriptionGroupName = "Photocore Plus"

    public var plan: Plan {
        switch self {
        case .plusMonthly, .plusYearly: .plus
        case .tripPass: .tripPass
        case .eventPass: .eventPass
        }
    }

    /// Passes are spent on one book; Plus renews.
    public var isPass: Bool { plan == .tripPass || plan == .eventPass }
}

/// The rules that depend on time and counts rather than on the plan alone.
public enum PlanPolicy {
    public static let plusBooksPerYear = 12
    public static let freeBooksPerPhone = 1
    /// How long a free book stays up after it's first finished.
    public static let freeHosting: TimeInterval = 365 * 24 * 3600
    /// How long a Plus book stays up after the subscription ends.
    public static let plusGrace: TimeInterval = 365 * 24 * 3600

    /// When a book stops being served, or nil for never.
    public static func hostedUntil(plan: Plan, firstFinished: Date, subscriptionExpires: Date?) -> Date? {
        switch plan {
        case .free: firstFinished.addingTimeInterval(freeHosting)
        case .plus: (subscriptionExpires ?? firstFinished).addingTimeInterval(plusGrace)
        case .tripPass, .eventPass: nil
        }
    }

    /// Books started on one Plus subscription in the year before `now`.
    public static func plusBooksUsed(_ starts: [Date], now: Date = Date()) -> Int {
        starts.filter { now.timeIntervalSince($0) < 365 * 24 * 3600 }.count
    }
}
