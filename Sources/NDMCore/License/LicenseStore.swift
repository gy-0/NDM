import Foundation
import CryptoKit

/// A validated Pro license.
public struct License: Equatable, Sendable {
    public let email: String
    /// nil = perpetual. Licenses include one year of updates; expiry gates
    /// update entitlement server-side later, not app functionality.
    public let expiry: Date?
    public let raw: String

    public init(email: String, expiry: Date?, raw: String) {
        self.email = email
        self.expiry = expiry
        self.raw = raw
    }
}

public enum LicenseError: Error, Equatable {
    case invalidFormat
    case badSignature
    case expired
}

/// Offline-verifiable license keys (Ed25519-signed), persisted locally.
///
/// Key format: `NDMP1.<base64url(payload JSON)>.<base64url(signature)>`
/// payload: `{"email":"…","exp":"2027-07-16"}` (`exp` optional = perpetual).
/// The signing private key lives with the vendor (never in the app or repo).
public enum LicenseStore {
    /// Production license verification key (Ed25519 public key).
    public static let productionPublicKeyBase64 = "fXaJf4nrGzOrrGapr6P7m6KEJZd2PlW/Zsl8tpRbbeA="

    public static let keyPrefix = "NDMP1"
    private static let defaultsKey = "ProLicenseKey"
    private static let suiteName = "dev.ndm.open"

    // MARK: - Feature gates

    /// Free tier is genuinely usable — 4 connections already beats a browser.
    public static let freeMaxConnections = 4
    public static let proMaxConnections = 32

    public static func connectionsCap(isPro: Bool) -> Int {
        isPro ? proMaxConnections : freeMaxConnections
    }

    // MARK: - Validation

    public static func parse(
        key: String,
        publicKeyBase64: String = productionPublicKeyBase64,
        now: Date = Date()
    ) throws -> License {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == keyPrefix,
              let payloadData = base64urlDecode(String(parts[1])),
              let signature = base64urlDecode(String(parts[2])) else {
            throw LicenseError.invalidFormat
        }
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: payloadData) else {
            throw LicenseError.badSignature
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            throw LicenseError.invalidFormat
        }
        var expiry: Date?
        if let exp = payload.exp {
            guard let date = Self.dayFormatter.date(from: exp) else {
                throw LicenseError.invalidFormat
            }
            if date < now {
                throw LicenseError.expired
            }
            expiry = date
        }
        return License(email: payload.email, expiry: expiry, raw: trimmed)
    }

    /// Vendor-side key generation (used by tooling/tests; the private key
    /// never ships with the app).
    public static func makeKey(
        email: String,
        expiry: Date?,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let payload = Payload(email: email, exp: expiry.map(Self.dayFormatter.string(from:)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let signature = try privateKey.signature(for: data)
        return [keyPrefix, base64urlEncode(data), base64urlEncode(signature)].joined(separator: ".")
    }

    // MARK: - Persistence

    public static func activate(_ key: String) throws -> License {
        let license = try parse(key: key)
        defaults?.set(license.raw, forKey: defaultsKey)
        return license
    }

    public static func deactivate() {
        defaults?.removeObject(forKey: defaultsKey)
    }

    /// The persisted license, re-validated on every load.
    public static func current() -> License? {
        guard let raw = defaults?.string(forKey: defaultsKey) else { return nil }
        return try? parse(key: raw)
    }

    public static var isPro: Bool { current() != nil }

    // MARK: - Internals

    private struct Payload: Codable {
        var email: String
        var exp: String?
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
