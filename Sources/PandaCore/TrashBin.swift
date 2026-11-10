import Foundation

/// The Trash of the user: `~/.Trash`. We only measure it.
/// To empty it, we ask Finder. Finder is the system way, and it handles locked files and the user's own Finder settings.
/// Trash Panda never deletes a file in the Trash by itself.
public enum TrashBin {
    /// The folder. External drives have their own Trash. We do not read those.
    public static func url(home: URL) -> URL { home.appendingPathComponent(".Trash", isDirectory: true) }

    /// What the Trash holds, in bytes. Zero when it is empty, missing, or cannot be read.
    public static func bytes(home: URL) -> Int64 {
        let folder = url(home: home)
        guard readable(folder) else { return 0 }
        return Sizer.size(of: folder)
    }

    /// False when macOS does not let this app read the Trash. Without Full Disk Access, it often does not.
    public static func readable(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// The one command that we send to Finder.
    public static let finderCommand = "tell application \"Finder\" to empty the trash"

    /// Asks Finder to empty the Trash. The first time, macOS asks the user to let Trash Panda control Finder.
    public static func emptyWithFinder() -> Result<Void, TrashRefusal> {
        guard let osascript = Shell.resolve("osascript") else { return .failure(.noScriptTool) }
        let result = Shell.run(osascript, ["-e", finderCommand], timeout: 600)
        return classify(status: result.status, stderr: result.stderr, timedOut: result.timedOut)
    }

    /// Turns the result of the command into success or a reason. Tests call this with made-up results.
    static func classify(status: Int32, stderr: String, timedOut: Bool) -> Result<Void, TrashRefusal> {
        if timedOut { return .failure(.timedOut) }
        if status == 0 { return .success(()) }
        // -1743 is the error that macOS gives when the user did not allow the control of Finder.
        if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") { return .failure(.notAllowed) }
        return .failure(.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

public enum TrashRefusal: Error, Equatable, Sendable {
    case noScriptTool, timedOut, notAllowed
    case failed(String)

    public var text: String {
        switch self {
        case .noScriptTool: return "osascript was not found"
        case .timedOut: return "Finder did not finish in time"
        case .notAllowed:
            return "macOS did not let Trash Panda control Finder. Allow it in System Settings, Privacy & Security, Automation."
        case .failed(let detail): return detail.isEmpty ? "Finder could not empty the Trash" : "Finder could not empty the Trash: \(detail)"
        }
    }
}
