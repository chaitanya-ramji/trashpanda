import Foundation

/// A request to stop a clean. The menu sets it on the main thread. The cleaner reads it on another thread.
public final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    public init() {}

    public var isRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    /// Clears the request before a new clean.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        requested = false
    }

    public func request() {
        lock.lock(); defer { lock.unlock() }
        requested = true
    }
}

public enum CleanProgress {
    /// The first menu row during a clean, for example "Cleaning 3 of 38 · Xcode build data".
    /// `number` counts from 1.
    public static func text(number: Int, total: Int, title: String) -> String {
        "Cleaning \(number) of \(total) · \(title)"
    }
}

/// Lets at most a few progress texts through each second, and always the last one.
/// The open menu is rebuilt for each text, so a text for each item would make the rows jump under the pointer.
/// Call it from one thread only.
public final class ProgressThrottle {
    private let interval: TimeInterval
    private let clock: () -> TimeInterval
    private var lastShown: TimeInterval?

    public init(interval: TimeInterval = 0.25, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.clock = clock
    }

    public func shouldShow(number: Int, total: Int) -> Bool {
        let now = clock()
        if number >= total || lastShown == nil || now - lastShown! >= interval {
            lastShown = now
            return true
        }
        return false
    }
}
