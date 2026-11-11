import Foundation
import CryptoKit

/// The websites that have saved files in `Service Worker/CacheStorage` of a Chromium browser (#44).
/// Each website has its own folder. The name of the folder is the SHA-1 of the storage key of the site, for example
/// `sha1("https_www.example.com_0")`. That is checked on a real profile of Arc.
///
/// The folder does not say the host name. We find candidate host names as plain text in the files of the folder (`index.txt`:
/// the names of the caches often hold an address), and we keep a candidate only when its hash is the name of the folder.
/// So a name that we show is proven, and a site with no proven name is shown as "Offline data of a website (name not known)". We never run a file and never show
/// more than the host name (no path, no query, no token). The text is read as bytes with a size limit.
public enum ServiceWorkerSites {
    /// How much of a file we read to look for a host name.
    static let readLimit = 65_536
    static let maximumCandidates = 24

    public struct Site: Equatable, Sendable {
        public let profile: String
        /// The name of the site folder: 40 hex characters.
        public let folder: String
        public let url: URL
        public let bytes: Int64
        /// The proven host name, or nil.
        public let host: String?

        public var title: String { host.map { "Offline website · \($0)" } ?? "Offline data of a website (name not known)" }
    }

    /// True for the name of a site folder: the 40 lower case hex characters of a SHA-1.
    public static func isSiteFolderName(_ text: String) -> Bool {
        text.range(of: #"^[0-9a-f]{40}\z"#, options: .regularExpression) != nil
    }

    public static func storageKeyHash(scheme: String, host: String) -> String {
        let key = "\(scheme)_\(host)_0"
        return Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A host name that is safe to show: lower case letters, digits, dots, and dashes, with a dot, or `localhost`.
    static func isHost(_ text: String) -> Bool {
        text.count <= 253 && (text == "localhost" || (text.contains(".") && text.range(
            of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z"#, options: .regularExpression) != nil))
    }

    private static let address = try! NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]{1,253})"#)

    /// The host names that appear as `http://host` or `https://host` in some bytes. Only the host part is kept.
    static func candidates(in data: Data) -> [(scheme: String, host: String)] {
        let text = String(decoding: data.prefix(readLimit).map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self)
        var seen: Set<String> = []
        var out: [(String, String)] = []
        for m in address.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let hostRange = Range(m.range(at: 1), in: text) else { continue }
            let scheme = text[whole].hasPrefix("https") ? "https" : "http"
            let host = text[hostRange].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard isHost(host), seen.insert("\(scheme)_\(host)").inserted else { continue }
            out.append((scheme, host))
            if out.count >= maximumCandidates { break }
        }
        return out
    }

    /// The proven host of a site folder, or nil. A candidate counts only when its storage key hash is the folder name.
    static func provenHost(folder: URL) -> String? {
        let name = folder.lastPathComponent
        guard isSiteFolderName(name) else { return nil }
        let fm = FileManager.default
        var files: [URL] = [folder.appendingPathComponent("index.txt")]
        // The cache folders of the site have files of their own. We read a few of them too. Their names are ids, not paths.
        for child in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().prefix(8) where child != "index.txt" {
            files.append(folder.appendingPathComponent(child).appendingPathComponent("index.txt"))
        }
        for file in files {
            guard (try? fm.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType == .typeRegular,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = (try? handle.read(upToCount: readLimit)) ?? Data()
            try? handle.close()
            for (scheme, host) in candidates(in: data) where storageKeyHash(scheme: scheme, host: host) == name { return host }
        }
        return nil
    }

    /// Every site folder of every profile of a browser, now. A link, a file, and a folder with another name are left out.
    public static func sites(of browser: Browser, home: URL) -> [Site] {
        guard browser.kind == .chromium else { return [] }
        let fm = FileManager.default
        func isFolder(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory && UpdateDownloads.isPlainPath(url) }
        var out: [Site] = []
        for root in browser.roots {
            let rootURL = home.appendingPathComponent(root, isDirectory: true)
            guard isFolder(rootURL) else { continue }
            for profile in ((try? fm.contentsOfDirectory(atPath: rootURL.path)) ?? []).sorted() where browser.isProfileName(profile) {
                let storage = BrowserCaches.serviceWorkerPath.reduce(rootURL.appendingPathComponent(profile, isDirectory: true)) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
                guard isFolder(storage) else { continue }
                for name in ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).sorted() where isSiteFolderName(name) {
                    let url = storage.appendingPathComponent(name, isDirectory: true)
                    guard isFolder(url) else { continue }
                    out.append(Site(profile: profile, folder: name, url: url, bytes: Sizer.size(of: url), host: provenHost(folder: url)))
                }
            }
        }
        return out
    }

    public static func site(browser: Browser, profile: String, folder: String, home: URL) -> Site? {
        guard isSiteFolderName(folder) else { return nil }
        return sites(of: browser, home: home).first { $0.profile == profile && $0.folder == folder }
    }

    /// True when `relative` (below home) is one site folder: `<root>/<profile>/Service Worker/CacheStorage/<40 hex>`.
    public static func isSiteShape(relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(""), !parts.contains("."), !parts.contains("..") else { return false }
        return BrowserCaches.browsers.contains { b in
            b.kind == .chromium && b.roots.contains { root in
                let r = root.split(separator: "/").map(String.init)
                return parts.count == r.count + 4 && Array(parts.prefix(r.count)) == r && b.isProfileName(parts[r.count])
                    && Array(parts[(r.count + 1)...].prefix(2)) == BrowserCaches.serviceWorkerPath && isSiteFolderName(parts[r.count + 3])
            }
        }
    }
}
