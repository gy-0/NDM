import Foundation

/// Strict parsers for settings fields. Invalid text returns nil instead of
/// silently changing a user's value to an unrelated default.
public enum SettingsInputValidation {
    public static func connectionCount(_ raw: String) -> Int? {
        guard let value = Int(trim(raw)), (1...32).contains(value) else { return nil }
        return value
    }

    public static func bandwidthBytesPerSecond(_ raw: String) -> Int64? {
        guard let value = Int64(trim(raw)), value >= 0 else { return nil }
        return value
    }

    public static func port(_ raw: String) -> UInt16? {
        guard let value = UInt16(trim(raw)), value > 0 else { return nil }
        return value
    }

    public static func nonEmptyText(_ raw: String) -> String? {
        let value = trim(raw)
        return value.isEmpty ? nil : value
    }

    private static func trim(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
