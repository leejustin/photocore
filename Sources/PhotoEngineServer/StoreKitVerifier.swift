import CryptoKit
import Foundation
import PhotoEngineWorkflow
import Security

/// A purchase as the App Store signed it (StoreKit 2 JWS transaction payload).
struct SignedTransaction: Decodable, Sendable, Equatable {
    var transactionId: String
    var originalTransactionId: String
    var bundleId: String
    var productId: String
    /// Milliseconds since 1970, as the App Store sends them.
    var purchaseDate: Double
    var expiresDate: Double?
    var revocationDate: Double?
    var environment: String

    var purchased: Date { Date(timeIntervalSince1970: purchaseDate / 1000) }
    var expires: Date? { expiresDate.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

enum StoreKitError: Error, Equatable, CustomStringConvertible {
    case malformed
    case untrusted(String)
    case badSignature
    case wrongApp
    case revoked
    case expired
    case unknownProduct

    var description: String {
        switch self {
        case .malformed: "That isn't an App Store purchase."
        case .untrusted(let why): "The App Store signature couldn't be trusted (\(why))."
        case .badSignature: "The App Store signature doesn't match."
        case .wrongApp: "That purchase belongs to a different app."
        case .revoked: "That purchase was refunded or revoked."
        case .expired: "That subscription has ended."
        case .unknownProduct: "That isn't a Photocore plan."
        }
    }
}

/// Checks StoreKit 2 signed transactions the way Apple describes: the x5c chain
/// must end at a pinned root (Apple Root CA - G3 in production), the leaf and
/// intermediate must carry Apple's marker extensions, and the ES256 signature
/// must verify with the leaf's key. Purchases made in Xcode's StoreKit testing
/// are signed locally and accepted only when `allowXcode` is on.
struct StoreKitVerifier: Sendable {
    var anchors: [Data]
    var bundleID: String
    var allowXcode: Bool

    static let appleRootG3 = Data(base64Encoded: "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==")!
    static let leafMarker = "1.2.840.113635.100.6.11.1"
    static let intermediateMarker = "1.2.840.113635.100.6.2.1"

    /// Production trusts only Apple. `PHOTOCORE_STOREKIT_TEST_ROOT` adds a test
    /// root and `PHOTOCORE_STOREKIT_XCODE=1` accepts Xcode test purchases; both are
    /// for local development and the checks.
    static func make(_ configuration: ServerConfiguration) -> StoreKitVerifier {
        var anchors = [appleRootG3]
        if let url = configuration.storeKitTestRoot, let data = try? Data(contentsOf: url) {
            anchors.append(data)
        }
        return StoreKitVerifier(anchors: anchors, bundleID: configuration.bundleID, allowXcode: configuration.allowXcodePurchases)
    }

    func verify(_ jws: String, now: Date = Date()) throws -> SignedTransaction {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Self.base64URL(parts[0]), let payloadData = Self.base64URL(parts[1]), let signature = Self.base64URL(parts[2]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData), header.alg == "ES256",
              let transaction = try? JSONDecoder().decode(SignedTransaction.self, from: payloadData)
        else { throw StoreKitError.malformed }
        let certificates = header.x5c.compactMap { Data(base64Encoded: $0) }
        guard !certificates.isEmpty, certificates.count == header.x5c.count else { throw StoreKitError.malformed }

        if transaction.environment == "Xcode" {
            guard allowXcode else { throw StoreKitError.untrusted("Xcode test purchases aren't accepted here") }
        } else {
            try verifyChain(certificates, at: now)
        }
        guard let leaf = SecCertificateCreateWithData(nil, certificates[0] as CFData),
              let key = SecCertificateCopyKey(leaf),
              let external = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: external),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { throw StoreKitError.badSignature }
        guard publicKey.isValidSignature(ecdsa, for: Data((parts[0] + "." + parts[1]).utf8)) else { throw StoreKitError.badSignature }

        guard transaction.bundleId == bundleID else { throw StoreKitError.wrongApp }
        guard transaction.revocationDate == nil else { throw StoreKitError.revoked }
        guard PlanProduct(rawValue: transaction.productId) != nil else { throw StoreKitError.unknownProduct }
        return transaction
    }

    private func verifyChain(_ certificates: [Data], at date: Date) throws {
        guard certificates.count >= 2 else { throw StoreKitError.untrusted("the chain is too short") }
        let chain = certificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        let roots = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard chain.count == certificates.count else { throw StoreKitError.malformed }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else {
            throw StoreKitError.untrusted("the chain couldn't be read")
        }
        SecTrustSetAnchorCertificates(trust, roots as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, date as CFDate)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw StoreKitError.untrusted("the chain doesn't lead to a trusted root")
        }
        #if os(macOS)
        guard Self.has(Self.leafMarker, chain[0]), Self.has(Self.intermediateMarker, chain[1]) else {
            throw StoreKitError.untrusted("the certificates aren't App Store signing certificates")
        }
        #endif
    }

    #if os(macOS)
    private static func has(_ oid: String, _ certificate: SecCertificate) -> Bool {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any] else { return false }
        return values[oid] != nil
    }
    #endif

    private struct Header: Decodable {
        var alg: String
        var x5c: [String]
    }

    static func base64URL(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}
