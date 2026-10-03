import Foundation
import PhotoEngineApple
import PhotoEnginePersistence

public struct ServerConfiguration: Sendable {
    public var port: Int
    public var security: WorkerSecurity
    public var catalogURL: URL
    public var mediaCacheDirectory: URL
    public var tokenWasGenerated: Bool
    /// The app whose App Store purchases unlock plans.
    public var bundleID: String
    /// An extra trusted root for signed purchases; only for tests and local development.
    public var storeKitTestRoot: URL?
    /// Accept purchases made with Xcode's StoreKit testing; only for local development.
    public var allowXcodePurchases: Bool
    /// Where the free-book footer links, if anywhere.
    public var siteURL: String?
    /// Bound on the App Store, where "Make one for your trip" sends iPhone visitors.
    public var appStoreURL: String?
    /// The public address of this server (`https://bound.example`), for links in
    /// emails, checkout returns and print files. Nil uses the loopback address.
    public var publicURL: String?
    /// Resend API key and sender for email; without both, emails go to an outbox folder.
    public var resendAPIKey: String?
    public var mailFrom: String?
    /// Lets the checks move a trip back in time. Never set in production.
    public var allowClockShift: Bool
    /// Stripe secret key and webhook signing secret for web purchases.
    public var stripeSecretKey: String?
    public var stripeWebhookSecret: String?
    /// Another Stripe API address; only for the checks' stand-in.
    public var stripeAPIBase: String?
    /// A checkout that charges nothing, for local development. Ignored when a
    /// Stripe key is set.
    public var devCheckout: Bool
    /// Lulu Print API credentials; printed copies are offered only with these
    /// (or with the test checkout).
    public var luluClientKey: String?
    public var luluClientSecret: String?
    /// `https://api.sandbox.lulu.com` while testing; Lulu's live API by default.
    public var luluAPIBase: String?
    public var luluSoftcoverPackage: String?
    public var luluHardcoverPackage: String?
    public var luluShippingLevel: String?
    /// The address Lulu writes to about orders.
    public var printContactEmail: String?
    /// Apple developer team id, for the App Clip and universal links file.
    public var appleTeamID: String?
    /// Bound's App Store id, for the banner that opens the App Clip from an invite.
    public var appStoreID: String?

    /// The App Clip's bundle id.
    public var appClipBundleID: String { bundleID + ".Clip" }

    public init(port: Int, security: WorkerSecurity, catalogURL: URL, mediaCacheDirectory: URL, tokenWasGenerated: Bool, bundleID: String = "com.photocore.trip", storeKitTestRoot: URL? = nil, allowXcodePurchases: Bool = false, siteURL: String? = nil, appStoreURL: String? = nil, publicURL: String? = nil, resendAPIKey: String? = nil, mailFrom: String? = nil, allowClockShift: Bool = false, stripeSecretKey: String? = nil, stripeWebhookSecret: String? = nil, stripeAPIBase: String? = nil, devCheckout: Bool = false, luluClientKey: String? = nil, luluClientSecret: String? = nil, luluAPIBase: String? = nil, luluSoftcoverPackage: String? = nil, luluHardcoverPackage: String? = nil, luluShippingLevel: String? = nil, printContactEmail: String? = nil, appleTeamID: String? = nil, appStoreID: String? = nil) {
        self.port = port
        self.security = security
        self.catalogURL = catalogURL
        self.mediaCacheDirectory = mediaCacheDirectory
        self.tokenWasGenerated = tokenWasGenerated
        self.bundleID = bundleID
        self.storeKitTestRoot = storeKitTestRoot
        self.allowXcodePurchases = allowXcodePurchases
        self.siteURL = siteURL
        self.appStoreURL = appStoreURL
        self.publicURL = publicURL.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        self.resendAPIKey = resendAPIKey
        self.mailFrom = mailFrom
        self.allowClockShift = allowClockShift
        self.stripeSecretKey = stripeSecretKey
        self.stripeWebhookSecret = stripeWebhookSecret
        self.stripeAPIBase = stripeAPIBase
        self.devCheckout = devCheckout
        self.luluClientKey = luluClientKey
        self.luluClientSecret = luluClientSecret
        self.luluAPIBase = luluAPIBase
        self.luluSoftcoverPackage = luluSoftcoverPackage
        self.luluHardcoverPackage = luluHardcoverPackage
        self.luluShippingLevel = luluShippingLevel
        self.printContactEmail = printContactEmail
        self.appleTeamID = appleTeamID
        self.appStoreID = appStoreID
    }

    /// The base for absolute links, with no trailing slash.
    public func publicBase(port: Int?) -> String {
        publicURL ?? "http://127.0.0.1:\(port ?? self.port)"
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ServerConfiguration {
        var token = environment["PHOTO_ENGINE_TOKEN"] ?? ""
        var generated = false
        if let filePath = environment["PHOTO_ENGINE_TOKEN_FILE"], !filePath.isEmpty {
            token = try tokenFromFile(URL(fileURLWithPath: filePath))
            generated = false
        } else if token.isEmpty {
            token = UUID().uuidString
            generated = true
        }
        let port = Int(environment["PHOTO_ENGINE_PORT"] ?? "") ?? 8787
        var security = WorkerSecurity.fromEnvironment(token: token, environment: environment)
        // One folder for everything the server writes, for development and deploys.
        let dataDirectory = environment["PHOTOCORE_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let dataDirectory { security.outputRoot = dataDirectory.appendingPathComponent("worker-runs", isDirectory: true) }
        let cache = dataDirectory?.appendingPathComponent("media", isDirectory: true) ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photocore/media", isDirectory: true)
        return ServerConfiguration(
            port: port,
            security: security,
            catalogURL: dataDirectory?.appendingPathComponent("catalog.sqlite") ?? PhotoCatalog.defaultURL(),
            mediaCacheDirectory: cache,
            tokenWasGenerated: generated,
            bundleID: environment["PHOTOCORE_BUNDLE_ID"] ?? "com.photocore.trip",
            storeKitTestRoot: environment["PHOTOCORE_STOREKIT_TEST_ROOT"].map { URL(fileURLWithPath: $0) },
            allowXcodePurchases: environment["PHOTOCORE_STOREKIT_XCODE"] == "1",
            siteURL: environment["PHOTOCORE_SITE_URL"],
            appStoreURL: environment["PHOTOCORE_APP_STORE_URL"],
            publicURL: environment["PHOTOCORE_PUBLIC_URL"],
            resendAPIKey: environment["RESEND_API_KEY"],
            mailFrom: environment["PHOTOCORE_MAIL_FROM"],
            stripeSecretKey: environment["STRIPE_SECRET_KEY"],
            stripeWebhookSecret: environment["STRIPE_WEBHOOK_SECRET"],
            devCheckout: environment["PHOTOCORE_DEV_CHECKOUT"] == "1",
            luluClientKey: environment["LULU_CLIENT_KEY"],
            luluClientSecret: environment["LULU_CLIENT_SECRET"],
            luluAPIBase: environment["LULU_API_BASE"],
            luluSoftcoverPackage: environment["LULU_POD_SOFTCOVER"],
            luluHardcoverPackage: environment["LULU_POD_HARDCOVER"],
            luluShippingLevel: environment["LULU_SHIPPING_LEVEL"],
            printContactEmail: environment["PHOTOCORE_PRINT_CONTACT"],
            appleTeamID: environment["PHOTOCORE_APPLE_TEAM_ID"],
            appStoreID: environment["PHOTOCORE_APP_STORE_ID"]
        )
    }

    /// Reads a token file. Creates a mode-600 file when it is missing.
    private static func tokenFromFile(_ url: URL) throws -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ServerConfigurationError.emptyTokenFile(url.path)
            }
            return token
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = UUID().uuidString
        try Data(token.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}

enum ServerConfigurationError: Error, CustomStringConvertible {
    case emptyTokenFile(String)

    var description: String {
        switch self {
        case .emptyTokenFile(let path): "PHOTO_ENGINE_TOKEN_FILE is empty: \(path)"
        }
    }
}
