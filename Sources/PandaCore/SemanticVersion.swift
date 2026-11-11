import Foundation

/// A version such as `1.2.3` or `1.2.3-beta.4`, with or without a `v` at the start.
/// Trash Panda uses it to compare its own releases, and the version folders of one AI tool use it too.
/// A release is newer than its own beta. Pre-release parts are compared one by one: numbers by value,
/// words by text, a number before a word, and more parts are newer.
public struct SemanticVersion: Comparable, Sendable, Hashable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The parts after the dash, for example `["beta", "4"]`. Empty for a release.
    public let preRelease: [String]

    /// Three numbers (up to nine digits each) and an optional pre-release part after a dash.
    /// Any other text gives nil. A fourth number, a dot suffix (`2.1.10.tmp`) and a line break at the end are not accepted.
    public init?(_ text: String) {
        let body = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard body.range(of: #"^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-[A-Za-z0-9]+(\.[A-Za-z0-9]+)*)?\z"#, options: .regularExpression) != nil else { return nil }
        let halves = body.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = halves[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        preRelease = halves.count > 1 ? halves[1].split(separator: ".").map(String.init) : []
    }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        if a.preRelease.isEmpty || b.preRelease.isEmpty { return !a.preRelease.isEmpty && b.preRelease.isEmpty }
        for i in 0..<min(a.preRelease.count, b.preRelease.count) where a.preRelease[i] != b.preRelease[i] {
            switch (Int(a.preRelease[i]), Int(b.preRelease[i])) {
            case let (m?, n?): return m < n
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.preRelease[i] < b.preRelease[i]
            }
        }
        return a.preRelease.count < b.preRelease.count
    }
}
