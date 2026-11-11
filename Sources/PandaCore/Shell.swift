import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    /// True when the tool file was not safe, so the command did not start.
    public var refused = false
}

public enum Shell {
    /// Apps that start from Finder get a short PATH. We add the usual tool folders.
    /// Tests set this to hide the tools that are installed on the machine.
    public static var searchDirsOverride: [String]?

    public static var searchDirs: [String] {
        if let override = searchDirsOverride { return override }
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "/usr/local/go/bin", "\(home)/go/bin", "\(home)/.cargo/bin",
            "\(home)/.local/bin", "\(home)/.orbstack/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
    }

    /// System tools have one fixed path. We never search for them, so a file with the same name
    /// in a folder that the user can write to is never used.
    public static let systemTools: [String: String] = [
        "osascript": "/usr/bin/osascript",
        "xcrun": "/usr/bin/xcrun",
        "xcode-select": "/usr/bin/xcode-select",
        "tmutil": "/usr/bin/tmutil",
        "lsof": "/usr/sbin/lsof",
        "ps": "/bin/ps",
    ]

    public static func resolve(_ tool: String) -> String? {
        let fm = FileManager.default
        if let fixed = systemTools[tool] {
            // Only tests set the override, to hide a tool. A fixed tool is hidden unless its own folder is in the list.
            // The override never moves a fixed tool to another folder.
            if let override = searchDirsOverride, !override.contains((fixed as NSString).deletingLastPathComponent) { return nil }
            return fm.isExecutableFile(atPath: fixed) ? fixed : nil
        }
        for dir in searchDirs {
            let path = "\(dir)/\(tool)"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// A tool file is trusted when its owner is root or the current user, and group and others cannot write to it.
    /// Links are resolved first, so the check is on the real file.
    public static func isTrustedBinary(_ url: URL) -> Bool { untrustedReason(url) == nil }

    static func untrustedReason(_ url: URL) -> String? {
        let real = url.resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real) else { return "the file cannot be read" }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        if owner != 0 && owner != getuid() { return "the owner of \(real) is not root or the current user" }
        if mode & 0o022 != 0 { return "group or others can write to \(real)" }
        return nil
    }

    /// Runs a command and logs it. The log has the command, the exit code, the time, and the end of stderr.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30,
                           unsetEnv: [String] = [], quiet: Bool = false) -> ShellResult {
        Shell.run(path, args, timeout: timeout, unsetEnvironment: unsetEnv, quiet: quiet)
    }

    /// Same as `run`. `unsetEnvironment` lists variables to remove from the command environment.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30,
                           unsetEnvironment: [String], quiet: Bool = false) -> ShellResult {
        let started = Date()
        if let reason = untrustedReason(URL(fileURLWithPath: path)) {
            Log.error("refused to run \(path): \(reason)")
            return ShellResult(status: -1, stdout: "", stderr: "The tool is not safe to run", timedOut: false, refused: true)
        }
        let result = execute(path, args, timeout: timeout, unset: unsetEnvironment)
        if quiet && result.status == 0 { return result }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        var line = "run \((path as NSString).lastPathComponent) \(args.joined(separator: " ")) -> exit \(result.status) in \(seconds)s"
        if result.timedOut { line += " TIMED OUT" }
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0, !err.isEmpty { line += " stderr: \(err.suffix(300))" }
        result.status == 0 ? Log.info(line) : Log.warn(line)
        return result
    }

    private static func execute(_ path: String, _ args: [String], timeout: TimeInterval,
                                unset: [String] = []) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("LD_") { env.removeValue(forKey: key) }
        for key in unset { env.removeValue(forKey: key) }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: "could not start: \(error.localizedDescription)", timedOut: false)
        }

        var outData = Data(), errData = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 3)
        }
        _ = readers.wait(timeout: .now() + 3)
        let status = process.isRunning ? -1 : process.terminationStatus
        return ShellResult(status: status, stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    }

    /// Working directories of all running processes. A project that a process uses is in use.
    public static func activeDirectories() -> [String] {
        let r = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn"], timeout: 15)
        return r.stdout.split(separator: "\n").compactMap { line in
            line.hasPrefix("n/") ? String(line.dropFirst()) : nil
        }
    }
}
