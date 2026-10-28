import Foundation

/// The `timestamp` field of a transcript line: ISO 8601, with or without
/// fractional seconds.
enum TranscriptTimestamp {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func parse(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
