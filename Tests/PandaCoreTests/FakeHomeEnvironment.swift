import Foundation

/// The environment for a program that a test starts (the built `trashpanda` binary, or a scratch program), so that it uses a
/// fake home folder and never the real one.
///
/// `HOME=<temp folder>` is NOT enough on this macOS. `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` still
/// return the REAL home folder, and only `CFFIXED_USER_HOME` moves them. A program that is started with only `HOME` can
/// therefore still read or write the real home. Always set BOTH variables, and always build the environment with this helper.
/// The product has no `--home` option and no override of its own, and it must not get one.
enum FakeHomeEnvironment {
    /// The two variables that must both point to the fake home.
    static let variables = ["HOME", "CFFIXED_USER_HOME"]

    /// `base` with both variables set to `home`. Pass the result to `Process.environment`.
    static func environment(for home: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for name in variables { env[name] = home.path }
        return env
    }

    /// True only when BOTH variables point to `home`. An environment with only `HOME` is not isolated.
    static func isIsolated(_ env: [String: String], home: URL) -> Bool {
        variables.allSatisfy { env[$0] == home.path }
    }
}
