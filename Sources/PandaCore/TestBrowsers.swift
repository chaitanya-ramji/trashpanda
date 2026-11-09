import Foundation

/// Browsers that test tools download: Playwright, Cypress, and Puppeteer (Chrome for Testing).
/// Each tool keeps every version that it ever downloaded. A project needs only one of them, and the tool
/// downloads another one when a project asks for it. We keep the newest version of each kind and offer the older ones.
public struct TestBrowserTool: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        /// Version folders are directly in the root, for example `chromium-1248`.
        case flat
        /// Version folders are in a folder for each browser, for example `chrome/mac_arm-121.0.6167.85`.
        case nested
    }

    public let id: String
    public let name: String
    /// Relative to the home folder.
    public let root: String
    public let layout: Layout
}

public enum TestBrowsers {
    static let tools: [TestBrowserTool] = [
        TestBrowserTool(id: "playwright", name: "Playwright", root: "Library/Caches/ms-playwright", layout: .flat),
        TestBrowserTool(id: "cypress", name: "Cypress", root: "Library/Caches/Cypress", layout: .flat),
        TestBrowserTool(id: "puppeteer", name: "Puppeteer", root: ".cache/puppeteer", layout: .nested),
    ]

    public static func tool(id: String) -> TestBrowserTool? { tools.first { $0.id == id } }

    /// One version folder: the kind of browser it belongs to, and its version as numbers.
    struct Entry: Equatable {
        let url: URL
        let group: String
        let version: [Int]
    }

    /// Reads the name of a version folder. A name in any other shape returns nil, and the folder is left alone.
    static func parse(name: String, tool: TestBrowserTool, browser: String? = nil) -> (group: String, version: [Int])? {
        func numbers(_ s: String) -> [Int]? {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return parts.contains(where: { $0 == nil }) || parts.isEmpty ? nil : parts.map { $0! }
        }
        switch tool.id {
        case "playwright":
            // chromium-1248, chromium_headless_shell-1248, ffmpeg-1013
            guard let m = name.range(of: #"^[a-z][a-z0-9_]*-[0-9]+$"#, options: .regularExpression), m.lowerBound == name.startIndex,
                  let dash = name.lastIndex(of: "-"), let v = numbers(String(name[name.index(after: dash)...])) else { return nil }
            return (String(name[..<dash]), v)
        case "cypress":
            guard name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil, let v = numbers(name) else { return nil }
            return ("cypress", v)
        case "puppeteer":
            // <browser>/<platform>-<version>, for example chrome/mac_arm-121.0.6167.85
            guard let browser, name.range(of: #"^[a-z][a-z0-9_]*-[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil,
                  let dash = name.firstIndex(of: "-"), let v = numbers(String(name[name.index(after: dash)...])) else { return nil }
            return ("\(browser)/\(name[..<dash])", v)
        default: return nil
        }
    }

    /// True when version `a` is newer than `b`. The numbers are compared one by one, so 1000 is newer than 999.
    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// All version folders of a tool. A link is never followed, and a path with a link in it is not used.
    static func entries(of tool: TestBrowserTool, home: URL) -> [Entry] {
        let fm = FileManager.default
        let root = home.appendingPathComponent(tool.root, isDirectory: true)
        guard isDirectory(root), UpdateDownloads.isPlainPath(root) else { return [] }
        var out: [Entry] = []
        func add(_ dir: URL, browser: String?) {
            for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(url), let p = parse(name: name, tool: tool, browser: browser) else { continue }
                out.append(Entry(url: url, group: p.group, version: p.version))
            }
        }
        switch tool.layout {
        case .flat: add(root, browser: nil)
        case .nested:
            for browser in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            where !browser.hasPrefix(".") && browser.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil {
                let dir = root.appendingPathComponent(browser, isDirectory: true)
                if isDirectory(dir) { add(dir, browser: browser) }
            }
        }
        return out
    }

    /// The folders that are not the newest of their kind. The newest of each kind always stays.
    public static func oldVersions(of tool: TestBrowserTool, home: URL) -> [URL] {
        let all = entries(of: tool, home: home)
        var newest: [String: Entry] = [:]
        for e in all where newest[e.group].map({ isNewer(e.version, than: $0.version) }) ?? true { newest[e.group] = e }
        return all.filter { newest[$0.group]?.url != $0.url }.map(\.url)
    }

    public static func bytes(of tool: TestBrowserTool, home: URL) -> Int64 {
        oldVersions(of: tool, home: home).reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
    }

    /// True when `url` is a version folder of this tool, in the right place and with a name that parses.
    static func isVersionFolder(_ url: URL, of tool: TestBrowserTool, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/" + tool.root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        switch tool.layout {
        case .flat: return parts.count == 1 && parse(name: parts[0], tool: tool) != nil
        case .nested: return parts.count == 2 && parse(name: parts[1], tool: tool, browser: parts[0]) != nil
        }
    }

    /// The full paths of the programs that run now. A version folder that one of them runs from is in use.
    public static func runningProgramPaths() -> [String] {
        let r = Shell.run("/bin/ps", ["-axo", "comm="], timeout: 5, quiet: true)
        return r.stdout.split(separator: "\n").map(String.init)
    }

    static func isInUse(_ folder: URL, programs: [String]) -> Bool {
        let prefix = folder.standardizedFileURL.path + "/"
        return programs.contains { $0.hasPrefix(prefix) }
    }
}
