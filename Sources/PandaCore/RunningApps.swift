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

    public func matches(bundleID: String) -> Bool {
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
    /// Reads what runs now. It can start a process and wait for it, so never call it on the main thread.
    public let take: @Sendable () -> RunningSnapshot
    private let store = Store()

    public init(_ take: @escaping @Sendable () -> RunningSnapshot) {
        self.take = take
    }

    /// The result of the last `refresh`. It is empty until the first one ends. Reading it is quick and starts nothing,
    /// so the menu can use it on the main thread.
    public var cached: RunningSnapshot { store.get() }

    /// Reads what runs on a background queue, keeps the result in `cached`, and then calls `then` on the main queue.
    public func refresh(then: @escaping @Sendable () -> Void) {
        let take = take, store = store
        DispatchQueue.global(qos: .userInitiated).async {
            store.set(take())
            DispatchQueue.main.async(execute: then)
        }
    }

    /// Holds the last result. A lock protects it, because `refresh` writes it on another thread.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var value = RunningSnapshot(apps: [])
        func get() -> RunningSnapshot { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: RunningSnapshot) { lock.lock(); value = new; lock.unlock() }
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
