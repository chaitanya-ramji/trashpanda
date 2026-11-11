import Foundation

/// Sizes in words, in decimal units, like Finder. The menu, the dialogs, and the bar all use this one.
public enum ByteText {
    public static func string(_ value: Int64) -> String {
        let v = Double(max(0, value))
        switch v {
        case 1e12...: return String(format: "%.1f TB", v / 1e12)
        case 1e10...: return String(format: "%.0f GB", v / 1e9)
        case 1e9...: return String(format: "%.1f GB", v / 1e9)
        case 1e6...: return String(format: "%.0f MB", v / 1e6)
        case 1e3...: return String(format: "%.0f KB", v / 1e3)
        case 1...: return "Less than 1 KB"
        default: return "0 KB"
        }
    }

    /// Parses "1.2GB (100%)" or "512kB", the way Docker and Homebrew write a size. They use decimal units.
    public static func parse(_ text: String) -> Int64? {
        let head = text.split(separator: " ").first.map(String.init) ?? text
        guard let range = head.range(of: "^[0-9.]+", options: .regularExpression),
              let value = Double(head[range]) else { return nil }
        let unit = head[range.upperBound...].lowercased()
        let scale: Double
        switch unit {
        case "b", "": scale = 1
        case "kb": scale = 1_000
        case "mb": scale = 1_000_000
        case "gb": scale = 1_000_000_000
        case "tb": scale = 1_000_000_000_000
        default: return nil
        }
        return Int64(value * scale)
    }
}
