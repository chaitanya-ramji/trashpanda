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
        default: return "0 KB"
        }
    }
}
