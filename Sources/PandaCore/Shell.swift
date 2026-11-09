import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
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

    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return ShellResult(status: -1, stdout: "", timedOut: false)
        }

        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 3)
        }
        _ = reader.wait(timeout: .now() + 3)
        let status = process.isRunning ? -1 : process.terminationStatus
        return ShellResult(status: status, stdout: String(decoding: data, as: UTF8.self), timedOut: timedOut)
    }

    /// Working directories of all running processes. A project that a process uses is in use.
    public static func activeDirectories() -> [String] {
        let r = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn"], timeout: 15)
        return r.stdout.split(separator: "\n").compactMap { line in
            line.hasPrefix("n/") ? String(line.dropFirst()) : nil
        }
    }
}
