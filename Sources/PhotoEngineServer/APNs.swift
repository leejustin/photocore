import CryptoKit
import Foundation

/// Apple Push Notification service with token authentication: a short JWT
/// signed with the team's .p8 key (ES256), reused for 50 minutes.
actor APNsPusher {
    let keyID: String
    let teamID: String
    let key: P256.Signing.PrivateKey
    let topic: String
    let base: URL
    private var cached: (token: String, made: Date)?

    init(keyID: String, teamID: String, key: P256.Signing.PrivateKey, topic: String, base: URL) {
        self.keyID = keyID
        self.teamID = teamID
        self.key = key
        self.topic = topic
        self.base = base
    }

    static func make(_ configuration: ServerConfiguration) -> APNsPusher? {
        guard let path = configuration.apnsKeyFile, let keyID = configuration.apnsKeyID, let team = configuration.appleTeamID,
              let pem = try? String(contentsOfFile: path, encoding: .utf8), let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { return nil }
        let base = configuration.apnsBase.flatMap(URL.init(string:))
            ?? URL(string: configuration.apnsSandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com")!
        return APNsPusher(keyID: keyID, teamID: team, key: key, topic: configuration.bundleID, base: base)
    }

    func jwt(now: Date = Date()) throws -> String {
        if let cached, now.timeIntervalSince(cached.made) < 50 * 60 { return cached.token }
        func encode(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let signing = try encode(["alg": "ES256", "kid": keyID]) + "." + encode(["iss": teamID, "iat": Int(now.timeIntervalSince1970)])
        let signature = try key.signature(for: Data(signing.utf8)).rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = signing + "." + signature
        cached = (token, now)
        return token
    }

    /// Sends an alert. Returns the HTTP status; 410 means the token is gone.
    func send(device: String, title: String, body: String, threadID: String? = nil) async throws -> Int {
        var request = URLRequest(url: base.appendingPathComponent("3/device/\(device)"))
        request.httpMethod = "POST"
        request.setValue("bearer \(try jwt())", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default"]
        if let threadID { aps["thread-id"] = threadID }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["aps": aps])
        request.assumesHTTP3Capable = false
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
