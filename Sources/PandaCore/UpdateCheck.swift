import Foundation

/// "Check for updates" (#32). Once a day, the app asks GitHub for the list of releases, and shows a menu line when a newer one exists.
///
/// What this does NOT do: it never downloads or installs anything. The menu line opens the release page in the browser, and the user
/// installs by hand. It sends only the request itself: no id, no version, no cookie, no body. The check can be turned off.
public enum UpdateCheck {
    public static let apiURL = URL(string: "https://api.github.com/repos/chaitanya-ramji/trashpanda/releases?per_page=15")!
    public static let releasesPage = URL(string: "https://github.com/chaitanya-ramji/trashpanda/releases")!
    /// The time between two automatic checks.
    public static let interval: TimeInterval = 86_400
    /// The most that we read from the answer.
    static let maximumBytes = 1_000_000

    public struct Release: Equatable, Sendable {
        /// The version without a leading `v`, for example `0.4.0-beta.5`.
        public let version: String
        public let tag: String
        public let url: URL
        public let isPrerelease: Bool
    }

    // MARK: Versions

    /// `v0.4.0-beta.5` and `0.4.0-beta.5` give `0.4.0-beta.5`. nil when the tag is not a version.
    public static func version(fromTag tag: String) -> String? {
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ClaudeVersions.isVersionName(text) ? text : nil
    }

    /// `0.4.0` is newer than `0.4.0-beta.5`, and `beta.10` is newer than `beta.9`.
    public static func isNewer(_ a: String, than b: String) -> Bool { ClaudeVersions.isNewer(a, than: b) }

    /// A beta user sees newer betas and newer stable versions. A user of a stable version sees stable versions only.
    public static func isPrerelease(version: String) -> Bool { version.contains("-") }

    // MARK: The answer of GitHub

    /// The page of a release must be on github.com, in this repository. Anything else is never opened.
    public static func isTrustedReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.port == nil
            && url.path.hasPrefix("/chaitanya-ramji/trashpanda/releases/")
    }

    /// The newest release that this version may be offered, or nil. It can be older than the current version.
    static func newestEligible(from data: Data, current: String) -> Release? {
        guard data.count <= maximumBytes, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let betaUser = isPrerelease(version: current)
        var best: Release?
        for entry in list {
            guard (entry["draft"] as? Bool) != true, let tag = entry["tag_name"] as? String, let v = version(fromTag: tag),
                  let page = (entry["html_url"] as? String).flatMap(URL.init(string:)), isTrustedReleaseURL(page) else { continue }
            let pre = (entry["prerelease"] as? Bool) == true || isPrerelease(version: v)
            if pre && !betaUser { continue }
            if best == nil || isNewer(v, than: best!.version) { best = Release(version: v, tag: tag, url: page, isPrerelease: pre) }
        }
        return best
    }

    /// The release to tell the user about: the newest eligible one, only when it is newer than the version that runs.
    public static func available(from data: Data, current: String) -> Release? {
        guard version(fromTag: current) != nil, let best = newestEligible(from: data, current: current),
              isNewer(best.version, than: current) else { return nil }
        return best
    }

    // MARK: The request

    /// The request. It has the address and two plain headers (what we accept, and a general name). Nothing else.
    public static func request() -> URLRequest {
        var r = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.httpMethod = "GET"
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("TrashPanda", forHTTPHeaderField: "User-Agent")
        r.httpShouldHandleCookies = false
        return r
    }

    /// A session that keeps nothing: no cookie, no cache, no stored credential.
    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    public enum Outcome: Equatable, Sendable {
        case newer(Release)
        case upToDate
        /// No answer, or an answer that we cannot read. The reason is for the log.
        case failed(String)
    }

    /// Asks GitHub. `fetch` returns the body and the status code. Tests give a fake. This call blocks, so call it off the main thread.
    public static func check(current: String, fetch: (URLRequest) -> (Data?, Int) = fetchWithSession) -> Outcome {
        guard version(fromTag: current) != nil else { return .failed("this build has no release version (\(current))") }
        let (data, status) = fetch(request())
        guard status == 200, let data else { return .failed("GitHub answered \(status)") }
        guard data.count <= maximumBytes, (try? JSONSerialization.jsonObject(with: data)) is [Any] else { return .failed("the answer could not be read") }
        if let release = available(from: data, current: current) { return .newer(release) }
        return .upToDate
    }

    public static func fetchWithSession(_ request: URLRequest) -> (Data?, Int) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, Int) = (nil, 0)
        let session = makeSession()
        let task = session.dataTask(with: request) { data, response, _ in
            result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 35) == .timedOut { task.cancel() }
        session.finishTasksAndInvalidate()
        return result
    }
}

/// What the user chose, and when we last asked. Kept in the settings of the app. The automatic check can be turned off.
public struct UpdatePreferences {
    private let defaults: UserDefaults
    static let enabledKey = "updateCheckEnabled"
    static let lastCheckKey = "updateLastCheck"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// On by default. The user can turn it off in the menu.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var lastCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    public func markChecked(_ now: Date = Date()) { defaults.set(now, forKey: Self.lastCheckKey) }

    /// True when an automatic check is due: it is on, and it is the first one, or a day passed, or the clock went back.
    public func isDue(now: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        guard let last = lastCheck else { return true }
        let passed = now.timeIntervalSince(last)
        return passed >= UpdateCheck.interval || passed < 0
    }
}
