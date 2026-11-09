import Foundation

/// A Chromium browser. It keeps a cache in the profile folder and another one in `~/Library/Caches`.
public struct Browser: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case chromium, firefox }

    public let id: String
    public let name: String
    public let bundleID: String
    /// Folders that hold the profiles, relative to the home folder.
    public let roots: [String]
    public var kind: Kind = .chromium

    /// The browser itself and its helper programs. If any of them runs, the caches are in use.
    /// Firefox Developer Edition and Nightly share the folder of Firefox, so a family name covers them.
    public var owner: AppOwner {
        kind == .firefox ? AppOwner(name: name, bundleIDs: [bundleID + "*"])
                         : AppOwner(name: name, bundleIDs: [bundleID, bundleID + ".helper*"])
    }

    /// The only folder names that we clean inside a profile of this browser.
    var cacheNames: Set<String> { kind == .firefox ? BrowserCaches.firefoxCacheNames : BrowserCaches.cacheNames }

    func isProfileName(_ name: String) -> Bool {
        kind == .firefox ? BrowserCaches.isFirefoxProfileName(name) : BrowserCaches.isProfileName(name)
    }
}

/// Caches of Chromium browsers. We clean **only** these folders inside a profile:
/// `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache`.
/// A browser makes them again. We never touch cookies, logins, history, local storage, IndexedDB, extensions,
/// preferences, sessions, or Service Worker storage. A list of names is the only way that we find a folder.
public enum BrowserCaches {
    static let browsers: [Browser] = [
        Browser(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome",
                roots: ["Library/Application Support/Google/Chrome", "Library/Caches/Google/Chrome"]),
        Browser(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser",
                roots: ["Library/Application Support/Arc/User Data", "Library/Caches/Arc/User Data"]),
        Browser(id: "brave", name: "Brave", bundleID: "com.brave.Browser",
                roots: ["Library/Application Support/BraveSoftware/Brave-Browser", "Library/Caches/BraveSoftware/Brave-Browser"]),
        Browser(id: "edge", name: "Edge", bundleID: "com.microsoft.edgemac",
                roots: ["Library/Application Support/Microsoft Edge", "Library/Caches/Microsoft Edge"]),
        Browser(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
                roots: ["Library/Application Support/Vivaldi", "Library/Caches/Vivaldi"]),
        Browser(id: "opera", name: "Opera", bundleID: "com.operasoftware.Opera",
                roots: ["Library/Application Support/com.operasoftware.Opera", "Library/Caches/com.operasoftware.Opera"]),
        // Firefox keeps its caches only in Library/Caches. The profile folder holds the user data and is not a root here.
        Browser(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox",
                roots: ["Library/Caches/Firefox/Profiles"], kind: .firefox),
    ]

    /// The only folder names that we clean inside a profile.
    static let cacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
                                          "DawnWebGPUCache", "GrShaderCache", "ShaderCache"]

    /// The only folder names that we clean inside a Firefox profile.
    static let firefoxCacheNames: Set<String> = ["cache2", "startupCache"]

    /// `abcd1234.default-release`: eight letters or digits, a dot, and a name.
    static func isFirefoxProfileName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9]{8}\.[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil && !name.contains("..")
    }

    public static func browser(id: String) -> Browser? { browsers.first { $0.id == id } }

    /// `Default`, `Profile 1`, `Profile 12`. Not `Guest Profile`, not `System Profile`.
    static func isProfileName(_ name: String) -> Bool {
        name == "Default" || name.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil
    }

    /// True for `<root>/<profile>/<cache name>` of a known browser, and for nothing else.
    /// `relative` is a path from the home folder. The path guard uses this as its one exception
    /// inside `Library/Application Support`.
    public static func isCacheShape(relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(""), !parts.contains("."), !parts.contains("..") else { return false }
        return browsers.contains { b in
            b.roots.contains { root in
                let r = root.split(separator: "/").map(String.init)
                return parts.count == r.count + 2 && Array(parts.prefix(r.count)) == r
                    && b.isProfileName(parts[r.count]) && b.cacheNames.contains(parts[r.count + 1])
            }
        }
    }

    /// The folders of a browser that we may clean, now. A link is never followed.
    public static func targets(of browser: Browser, home: URL) -> [URL] {
        let fm = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
        }
        var out: [URL] = []
        for root in browser.roots {
            let rootURL = home.appendingPathComponent(root, isDirectory: true)
            guard isDirectory(rootURL), UpdateDownloads.isPlainPath(rootURL) else { continue }
            for profile in ((try? fm.contentsOfDirectory(atPath: rootURL.path)) ?? []).sorted() where browser.isProfileName(profile) {
                let profileURL = rootURL.appendingPathComponent(profile, isDirectory: true)
                guard isDirectory(profileURL) else { continue }
                for name in browser.cacheNames.sorted() {
                    let url = profileURL.appendingPathComponent(name, isDirectory: true)
                    if isDirectory(url) { out.append(url) }
                }
            }
        }
        return out
    }

    public static func bytes(of browser: Browser, home: URL) -> Int64 {
        targets(of: browser, home: home).reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
    }

    /// True when `url` is one of the folders that we may clean for this browser.
    static func isTarget(_ url: URL, of browser: Browser, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix), isCacheShape(relative: String(path.dropFirst(prefix.count))) else { return false }
        return browser.roots.contains { path.hasPrefix(prefix + $0 + "/") }
    }
}
