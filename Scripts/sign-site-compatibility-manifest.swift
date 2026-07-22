#!/usr/bin/env swift

import CryptoKit
import Foundation

// Field-for-field mirror of SiteCompatibilityPayload in
// Sources/NDMEngine/SiteCompatibilityUpdater.swift; this script cannot import
// the module, so any change there must be mirrored here or the app will
// reject the signed manifest.
struct Payload: Codable {
    let schemaVersion: Int
    let version: String
    let publishedAt: String
    let minimumAppVersion: String
    let platform: String
    let assetURL: URL
    let sha256: String
    let byteCount: Int64
}

// Mirror of SignedSiteCompatibilityManifest in SiteCompatibilityUpdater.swift.
struct Envelope: Codable {
    let payload: String
    let signature: String
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count == 6 else {
    fail("usage: sign-site-compatibility-manifest.swift <binary> <version> <minimum-app-version> <https-asset-url> <output-json>")
}

let binaryURL = URL(fileURLWithPath: CommandLine.arguments[1])
let version = CommandLine.arguments[2]
let minimumAppVersion = CommandLine.arguments[3]
guard let assetURL = URL(string: CommandLine.arguments[4]),
      assetURL.scheme?.lowercased() == "https" else {
    fail("asset URL must use HTTPS")
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[5])
guard let rawPrivateKey = ProcessInfo.processInfo.environment["NDM_SITE_COMPATIBILITY_PRIVATE_KEY"],
      let privateKeyData = Data(base64Encoded: rawPrivateKey),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
    fail("NDM_SITE_COMPATIBILITY_PRIVATE_KEY must be a base64 Ed25519 private key")
}
guard let binary = try? Data(contentsOf: binaryURL), !binary.isEmpty else {
    fail("cannot read compatibility binary at \(binaryURL.path)")
}

let process = Process()
process.executableURL = binaryURL
process.arguments = ["--version"]
let output = Pipe()
process.standardOutput = output
process.standardError = output
do {
    try process.run()
} catch {
    fail("cannot execute compatibility binary: \(error.localizedDescription)")
}
// Drain the pipe before waiting so a chatty binary cannot deadlock the probe.
let versionOutput = output.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
let reportedVersion = String(data: versionOutput, encoding: .utf8)?
    .split(whereSeparator: \.isNewline).first.map(String.init)
guard process.terminationStatus == 0, reportedVersion == version else {
    fail("binary reports \(reportedVersion ?? "no version"), expected \(version)")
}

let digest = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
let payload = Payload(
    schemaVersion: 1,
    version: version,
    publishedAt: ISO8601DateFormatter().string(from: Date()),
    minimumAppVersion: minimumAppVersion,
    platform: "macos-universal",
    assetURL: assetURL,
    sha256: digest,
    byteCount: Int64(binary.count)
)
let payloadEncoder = JSONEncoder()
payloadEncoder.outputFormatting = [.sortedKeys]
let payloadData = try payloadEncoder.encode(payload)
let signature = try privateKey.signature(for: payloadData)
let envelope = Envelope(
    payload: payloadData.base64EncodedString(),
    signature: signature.base64EncodedString()
)
let envelopeEncoder = JSONEncoder()
envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let envelopeData = try envelopeEncoder.encode(envelope)
try envelopeData.write(to: outputURL, options: .atomic)

print("Signed site compatibility \(version) → \(outputURL.path)")
print("Public key: \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
