import Foundation

/// A simulator runtime: the system image that a simulator runs. Each one is several gigabytes.
public struct SimRuntime: Sendable, Equatable {
    /// The identifier of the runtime. `simctl runtime delete` takes it.
    public let id: String
    /// For example `com.apple.CoreSimulator.SimRuntime.iOS-17-5`.
    public let runtimeIdentifier: String
    public let version: String
    public let build: String
    public let sizeBytes: Int64
    /// `Ready`, `Unusable`, `Mounting`, `Verifying`, and so on.
    public let state: String
    /// `Disk Image`, `Cryptex`, `Legacy Download`, or `Bundled with Xcode`.
    public let kind: String
    public let deletable: Bool
    public let lastUsedAt: Date?

    /// `iOS`, `watchOS`, `tvOS`, or `visionOS`.
    public var platform: String {
        let tail = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        let name = tail.split(separator: "-").first.map(String.init) ?? tail
        return name == "xrOS" ? "visionOS" : name
    }

    public var displayName: String { "\(platform) \(version)" }

    /// A runtime that we may offer to remove: one that Xcode can delete, that is not part of Xcode,
    /// and that is not changing state now.
    public var isRemovableKind: Bool {
        deletable && kind != "Bundled with Xcode" && ["Ready", "Unusable"].contains(state)
    }

    /// Compares versions as numbers, so that 17.10 is newer than 17.5.
    func isNewer(than other: SimRuntime) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.version.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return build > other.build
    }
}

/// A simulator device, for example "iPhone 15". It keeps its own apps and data.
public struct SimDevice: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let runtimeIdentifier: String
    /// `Booted`, `Shutdown`, `Booting`, `Shutting Down`, or `Creating`.
    public let state: String
    /// nil when `simctl` did not say. We then treat the device as not offered.
    public let isAvailable: Bool?
    public let dataPath: String?
    public let dataBytes: Int64?
    public let lastBootedAt: Date?

    /// A device that runs now, or that is about to start or stop.
    public var isActive: Bool { state != "Shutdown" }
}

/// Reads `xcrun simctl`. All parsing is strict about what we need and fails closed:
/// an item that we cannot read is left out, never guessed.
public struct Simctl: Sendable {
    public let xcrun: String

    public init(xcrun: String) { self.xcrun = xcrun }

    public func run(_ args: [String], timeout: TimeInterval = 60) -> ShellResult {
        Shell.run(xcrun, ["simctl"] + args, timeout: timeout)
    }

    public func runtimes() -> [SimRuntime]? {
        let r = run(["runtime", "list", "-j"], timeout: 60)
        guard r.status == 0, let list = Self.parseRuntimes(r.stdout) else {
            Log.warn("simctl runtime list unavailable")
            return nil
        }
        return list
    }

    public func devices() -> [SimDevice]? {
        let r = run(["list", "devices", "-j"], timeout: 60)
        guard r.status == 0, let list = Self.parseDevices(r.stdout) else {
            Log.warn("simctl device list unavailable")
            return nil
        }
        return list
    }

    // MARK: Parsing

    static func parseRuntimes(_ text: String) -> [SimRuntime]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // `simctl runtime list -j` gives an object whose keys are the identifiers.
        // We also accept a list of objects, in case a version of Xcode prints it that way.
        var entries: [(String?, [String: Any])] = []
        if let dict = root as? [String: Any] {
            for (key, value) in dict { if let item = value as? [String: Any] { entries.append((key, item)) } }
        } else if let array = root as? [[String: Any]] {
            entries = array.map { (nil, $0) }
        } else { return nil }

        return entries.compactMap { key, item in
            let id = (item["identifier"] as? String) ?? key ?? ""
            guard SimulatorAction.isUUID(id),
                  let runtimeIdentifier = item["runtimeIdentifier"] as? String, !runtimeIdentifier.isEmpty,
                  let version = item["version"] as? String, !version.isEmpty,
                  let size = number(item["sizeBytes"]) else { return nil }     // no size: left out
            return SimRuntime(id: id, runtimeIdentifier: runtimeIdentifier, version: version,
                              build: item["build"] as? String ?? "", sizeBytes: size,
                              state: item["state"] as? String ?? "", kind: item["kind"] as? String ?? "",
                              deletable: bool(item["deletable"]) ?? false,
                              lastUsedAt: (item["lastUsedAt"] as? String).flatMap(DockerInventory.parseDate))
        }.sorted { $0.id < $1.id }
    }

    static func parseDevices(_ text: String) -> [SimDevice]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["devices"] as? [String: Any] else { return nil }
        var out: [SimDevice] = []
        for (runtime, value) in groups {
            for item in value as? [[String: Any]] ?? [] {
                guard let udid = item["udid"] as? String, SimulatorAction.isUUID(udid),
                      let state = item["state"] as? String else { continue }
                out.append(SimDevice(udid: udid, name: item["name"] as? String ?? udid, runtimeIdentifier: runtime,
                                     state: state, isAvailable: bool(item["isAvailable"]),
                                     dataPath: item["dataPath"] as? String, dataBytes: number(item["dataPathSize"]),
                                     lastBootedAt: (item["lastBootedAt"] as? String).flatMap(DockerInventory.parseDate)))
            }
        }
        return out.sorted { $0.udid < $1.udid }
    }

    /// A number or a string that holds a number. Zero and negative sizes are not trusted.
    private static func number(_ value: Any?) -> Int64? {
        // A JSON true or false is not a size. Swift can read the numbers 0 and 1 as booleans, so we ask the type.
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.int64Value >= 0 ? n.int64Value : nil }
        if let s = value as? String, let n = Int64(s), n >= 0 { return n }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let s = (value as? String)?.lowercased() { return s == "true" ? true : (s == "false" ? false : nil) }
        return nil
    }
}

/// The folder where Xcode keeps the archives of apps that you built for release.
public struct XcodeArchive: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let bytes: Int64
    public let modified: Date?
}

public enum XcodeArchives {
    public static func root(home: URL) -> URL {
        home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)
    }

    /// Lists `Archives/<date>/<name>.xcarchive`. A link is never followed.
    public static func list(home: URL) -> [XcodeArchive] {
        let fm = FileManager.default
        var out: [XcodeArchive] = []
        for day in (try? fm.contentsOfDirectory(atPath: root(home: home).path)) ?? [] {
            let dayURL = root(home: home).appendingPathComponent(day, isDirectory: true)
            guard isRealDirectory(dayURL) else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: dayURL.path)) ?? [] where name.hasSuffix(".xcarchive") {
                let url = dayURL.appendingPathComponent(name, isDirectory: true)
                guard isRealDirectory(url) else { continue }
                let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                out.append(XcodeArchive(url: url, name: String(name.dropLast(".xcarchive".count)),
                                        bytes: Sizer.size(of: url), modified: modified))
            }
        }
        return out
    }

    /// True only for `Archives/<date>/<name>.xcarchive`, two levels below the archives folder.
    public static func isArchive(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = root(home: home).standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix), path.hasSuffix(".xcarchive") else { return false }
        return path.dropFirst(prefix.count).split(separator: "/").count == 2
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }
}
