import Foundation

/// The symbol files that Xcode copies from a device the first time it sees a new OS version.
/// One folder for each device model and OS version, for example `iPhone15,2 17.5 (21F79)`.
/// They pile up for years and each one can be several gigabytes. Xcode copies them again when needed.
public struct DeviceSupportFolder: Sendable, Equatable {
    public let platform: String
    public let directory: String
    public let url: URL
    /// For example `iPhone15,2`. Older versions of Xcode did not put the model in the name.
    public let model: String?
    public let version: String
    public let build: String
    public let bytes: Int64
    public let modified: Date?

    public var name: String { url.lastPathComponent }

    /// Two folders belong together when they are for the same kind of device.
    var group: String { "\(platform)|\(model ?? "")" }

    /// Compares OS versions as numbers, so that 17.10 is newer than 17.5. The build breaks a tie.
    func isNewer(than other: DeviceSupportFolder) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.version.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return build > other.build
    }
}

public enum DeviceSupport {
    /// The folder of each platform, and the name that we show.
    static let platforms: [(directory: String, name: String)] = [
        ("iOS DeviceSupport", "iOS"), ("watchOS DeviceSupport", "watchOS"),
        ("tvOS DeviceSupport", "tvOS"), ("visionOS DeviceSupport", "visionOS"),
    ]

    public static func root(home: URL) -> URL {
        home.appendingPathComponent("Library/Developer/Xcode", isDirectory: true)
    }

    /// Reads `iPhone15,2 17.5 (21F79)`, or `10.3.3 (14G60)` from an older Xcode. A name in any other shape returns nil.
    /// A folder with such a name is not ours, so it is left alone.
    public static func parse(name: String) -> (model: String?, version: String, build: String)? {
        let pattern = #"^(?:([A-Za-z]+[0-9]+,[0-9]+) )?([0-9]+(?:\.[0-9]+){0,2}) \(([0-9A-Za-z]+)\)(?: (?:arm64e|arm64_32|arm64|armv7s|armv7))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        func part(_ i: Int) -> String? { Range(m.range(at: i), in: name).map { String(name[$0]) } }
        guard let version = part(2), let build = part(3) else { return nil }
        return (part(1), version, build)
    }

    /// Lists the folders of every platform. A link is never followed, and a name that does not parse is skipped.
    public static func list(home: URL) -> [DeviceSupportFolder] {
        let fm = FileManager.default
        var out: [DeviceSupportFolder] = []
        for (directory, platform) in platforms {
            let dir = root(home: home).appendingPathComponent(directory, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard let parsed = parse(name: name) else { continue }
                let url = dir.appendingPathComponent(name, isDirectory: true)
                guard (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory else { continue }
                out.append(DeviceSupportFolder(
                    platform: platform, directory: directory, url: url, model: parsed.model, version: parsed.version,
                    build: parsed.build, bytes: Sizer.size(of: url),
                    modified: (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date))
            }
        }
        return out
    }

    /// True only for `Library/Developer/Xcode/<platform> DeviceSupport/<name>`, with a name that parses.
    public static func isDeviceSupport(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = root(home: home).standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        return parts.count == 2 && platforms.contains { $0.directory == parts[0] } && parse(name: parts[1]) != nil
    }

    /// The newest folder of each device model. We keep these.
    static func newest(_ folders: [DeviceSupportFolder]) -> Set<URL> {
        var best: [String: DeviceSupportFolder] = [:]
        for f in folders where best[f.group].map({ f.isNewer(than: $0) }) ?? true { best[f.group] = f }
        return Set(best.values.map(\.url))
    }
}
