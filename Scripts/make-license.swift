// Vendor tool: mint a Pro license key.
// Usage: swift Scripts/make-license.swift buyer@example.com [2027-07-16]
// Reads the private key from ~/.ndm-license/signing-key.txt (never in repo).
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: swift Scripts/make-license.swift <email> [expiry yyyy-MM-dd]")
    exit(1)
}
let email = args[1]
let exp = args.count >= 3 ? args[2] : nil

let keyFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".ndm-license/signing-key.txt")
guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("PRIVATE=") }),
      let keyData = Data(base64Encoded: String(line.dropFirst("PRIVATE=".count))),
      let signer = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    print("error: cannot read PRIVATE= from \(keyFile.path)")
    exit(1)
}

struct Payload: Codable { var email: String; var exp: String? }
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let payload = try encoder.encode(Payload(email: email, exp: exp))
let sig = try signer.signature(for: payload)

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
print("NDMP1.\(b64url(payload)).\(b64url(sig))")
