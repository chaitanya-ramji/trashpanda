import AppKit

/// The app, or apps, that use an item. Cleaning the item while the app runs can break the app.
/// For example, Xcode keeps its build data in DerivedData.
public struct AppOwner: Sendable, Equatable {
    /// How the menu names the owner when no running app gives a better name.
    public let name: String
    /// Bundle IDs. A trailing `*` matches every ID that starts with the text before it.
    public let bundleIDs: [String]
    /// Command line programs that also use the item, for example `xcodebuild`. They have no bundle ID.
    public let processNames: [String]

    public init(name: String, bundleIDs: [String], processNames: [String] = []) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.processNames = processNames
    }

    func matches(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return bundleIDs.contains { pattern in
            let p = pattern.lowercased()
            return p.hasSuffix("*") ? id.hasPrefix(String(p.dropLast())) : id == p
        }
    }
}

public struct RunningApp: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// What runs on this Mac at one moment.
public struct RunningSnapshot: Sendable {
    public let apps: [RunningApp]
    public let processes: Set<String>

    public init(apps: [RunningApp], processes: Set<String> = []) {
        self.apps = apps
        self.processes = processes
    }

    /// The names of the programs of `owner` that run now. The list is empty when none runs.
    public func running(_ owner: AppOwner) -> [String] {
        var names = apps.filter { owner.matches(bundleID: $0.bundleID) }.map(\.name)
        names += owner.processNames.filter { processes.contains($0) }
        return Array(Set(names)).sorted()
    }
}

/// Reads what runs. Tests give a fake one.
public struct RunningApps: Sendable {
    public let take: @Sendable () -> RunningSnapshot

    public init(_ take: @escaping @Sendable () -> RunningSnapshot) {
        self.take = take
    }

    public static let system = RunningApps {
        RunningSnapshot(apps: systemApps(), processes: systemProcesses())
    }

    private static func systemApps() -> [RunningApp] {
        let read: () -> [RunningApp] = {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return RunningApp(bundleID: id, name: app.localizedName ?? id)
            }
        }
        // NSWorkspace is read on the main thread.
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    private static func systemProcesses() -> Set<String> {
        let r = Shell.run("/bin/ps", ["-axo", "comm="], timeout: 5, quiet: true)
        return Set(r.stdout.split(separator: "\n").map { ($0 as NSString).lastPathComponent })
    }
}
