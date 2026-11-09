import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
}

public enum Shell {
    /// Apps that start from Finder get a short PATH. We add the usual tool folders.
    public static var searchDirs: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "/usr/local/go/bin", "\(home)/go/bin", "\(home)/.cargo/bin",
            "\(home)/.local/bin", "\(home)/.orbstack/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
    }

    public static func resolve(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            let path = "\(dir)/\(tool)"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a command and logs it. The log has the command, the exit code, the time, and the end of stderr.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> ShellResult {
        let started = Date()
        let result = execute(path, args, timeout: timeout)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        var line = "run \((path as NSString).lastPathComponent) \(args.joined(separator: " ")) -> exit \(result.status) in \(seconds)s"
        if result.timedOut { line += " TIMED OUT" }
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0, !err.isEmpty { line += " stderr: \(err.suffix(300))" }
        result.status == 0 ? Log.info(line) : Log.warn(line)
        return result
    }

    private static func execute(_ path: String, _ args: [String], timeout: TimeInterval) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
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
