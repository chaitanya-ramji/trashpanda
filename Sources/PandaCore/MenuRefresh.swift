import Foundation

/// Decides when the menu may be built again. A new build closes the submenu that the user reads,
/// so while the menu is open, a change only updates a few rows. The full build waits for the close.
public struct MenuRefreshGate: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// The menu is closed: build it now.
        case rebuild
        /// The menu is open: update the live rows and build after the close.
        case updateLiveRows
    }

    public private(set) var isOpen = false
    public private(set) var needsRebuild = false

    public init() {}

    /// The menu opened. The caller has just built it.
    public mutating func opened() {
        isOpen = true
        needsRebuild = false
    }

    /// The menu closed. Returns true when a change came while it was open, so the caller builds it now.
    public mutating func closed() -> Bool {
        isOpen = false
        defer { needsRebuild = false }
        return needsRebuild
    }

    /// The state changed. Say what to do.
    public mutating func changed() -> Decision {
        guard isOpen else { return .rebuild }
        needsRebuild = true
        return .updateLiveRows
    }
}
