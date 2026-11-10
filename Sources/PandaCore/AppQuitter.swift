import Foundation

/// Asks the apps that own an item to quit, and waits until they have. It never forces an app to quit:
/// a forced quit can lose unsaved work. If an app asks "Save changes?", the user answers it.
public struct AppQuitter {
    public enum Outcome: Equatable {
        /// Nothing of the owner runs any more.
        case quit
        /// These are still open after the wait.
        case stillOpen([String])
    }

    private let running: RunningApps
    private let ask: ([String]) -> Void
    private let pause: (TimeInterval) -> Void

    /// - Parameters:
    ///   - ask: gets the bundle IDs of the apps to ask. It must ask politely. The app target gives the real one.
    ///   - pause: waits. Tests give one that does not wait.
    public init(running: RunningApps = .system, ask: @escaping ([String]) -> Void,
                pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.running = running
        self.ask = ask
        self.pause = pause
    }

    /// The helper programs of a browser end when the main app ends. They are not asked.
    static func isHelper(_ bundleID: String) -> Bool { bundleID.lowercased().contains(".helper") }

    public func quit(_ owner: AppOwner, timeout: TimeInterval = 10, poll: TimeInterval = 0.25) -> Outcome {
        var snapshot = running.take()
        guard !snapshot.running(owner).isEmpty else { return .quit }
        let ids = snapshot.apps.filter { owner.matches(bundleID: $0.bundleID) && !Self.isHelper($0.bundleID) }.map(\.bundleID)
        Log.info("quit: asking \(snapshot.running(owner).joined(separator: ", ")) to quit")
        if !ids.isEmpty { ask(ids) }
        var waited: TimeInterval = 0
        while waited < timeout {
            pause(poll)
            waited += poll
            snapshot = running.take()
            if snapshot.running(owner).isEmpty { return .quit }
        }
        let left = snapshot.running(owner)
        Log.warn("quit: still open after \(timeout) s: \(left.joined(separator: ", "))")
        return .stillOpen(left)
    }
}
