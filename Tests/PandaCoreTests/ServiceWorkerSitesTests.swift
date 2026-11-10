import XCTest
@testable import PandaCore

/// #44: each website in the Service Worker storage is its own item. A name is shown only when the name of the folder proves it.
final class ServiceWorkerSitesTests: XCTestCase {
    private let support = "Library/Application Support/Arc/User Data"
    private var storage: String { "\(support)/Default/Service Worker/CacheStorage" }
    private func hash(_ host: String, scheme: String = "https") -> String { ServiceWorkerSites.storageKeyHash(scheme: scheme, host: host) }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ s: DiskScanner, running: [RunningApp] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private var arc: Browser { BrowserCaches.browser(id: "arc")! }

    /// A site folder with an `index.txt` that holds some text, and a cache folder with data.
    @discardableResult
    private func site(_ box: Sandbox, _ name: String, text: String? = nil, bytes: Int = 1_000_000, profile: String = "Default") throws -> String {
        let dir = "\(support)/\(profile)/Service Worker/CacheStorage/\(name)"
        try box.file("\(dir)/cache-1/0_0", bytes: bytes)
        if let text { try box.file("\(dir)/index.txt", bytes: 0); try text.write(to: box.home.appendingPathComponent("\(dir)/index.txt"), atomically: true, encoding: .utf8) }
        return dir
    }

    // MARK: The proof

    func testTheFolderNameIsTheHashOfTheStorageKey() {
        // The rule was checked on a real Arc profile: each site folder is named sha1("https_<host>_0"). This value is for example.com.
        XCTAssertEqual(hash("example.com"), "de7ccd9cfd2e93d02d0ea5612f42a59c5dba6e8f")
        XCTAssertNotEqual(hash("www.example.com", scheme: "http"), hash("www.example.com"))
        XCTAssertEqual(hash("example.com").count, 40)
    }

    func testFolderNameRules() {
        XCTAssertTrue(ServiceWorkerSites.isSiteFolderName(hash("example.com")))
        for bad in ["", "origin1", String(repeating: "a", count: 39), String(repeating: "a", count: 41), String(repeating: "A", count: 40),
                    String(repeating: "g", count: 40), hash("x") + "\n", "../" + String(repeating: "a", count: 37)] {
            XCTAssertFalse(ServiceWorkerSites.isSiteFolderName(bad), "\"\(bad)\"")
        }
    }

    func testOnlyTheHostIsTakenFromAnAddress() {
        let data = Data("workbox-precache-v2-https://www.example.com/some/path?token=SECRET123#frag and http://user:pw@login.example.org/x".utf8)
        let found = ServiceWorkerSites.candidates(in: data).map { "\($0.scheme)://\($0.host)" }
        XCTAssertEqual(found, ["https://www.example.com"], "The userinfo host `user` has no dot and is dropped, and `login.example.org` is behind `user:pw@`")
        XCTAssertFalse(found.joined().contains("SECRET"))
    }

    func testBytesThatAreNotTextAreSafe() {
        var bytes = Data([0xff, 0xfe, 0x00, 0x80, 0x90])
        bytes.append(Data("https://ok.example.com/".utf8))
        bytes.append(Data([0xc3, 0x28, 0xa0, 0xa1]))
        XCTAssertEqual(ServiceWorkerSites.candidates(in: bytes).map(\.host), ["ok.example.com"])
        XCTAssertTrue(ServiceWorkerSites.candidates(in: Data()).isEmpty)
    }

    func testHostRules() {
        for ok in ["example.com", "a.b.c.example.co.uk", "localhost", "xn--bcher-kva.example", "a-b.example.com"] { XCTAssertTrue(ServiceWorkerSites.isHost(ok), ok) }
        for bad in ["", "example", "-a.com", "a-.com", "a..com", ".com", "exa mple.com", "EXAMPLE.com", "a.com/", String(repeating: "a", count: 250) + ".com"] {
            XCTAssertFalse(ServiceWorkerSites.isHost(bad), bad)
        }
    }

    // MARK: A fake profile

    func testSeveralSitesAnUnreadableNameAndASpoofedName() throws {
        let box = try Sandbox()
        try site(box, hash("www.example.com"), text: "$aaaa\n)workbox-precache-v2-https://www.example.com/\nstart-url", bytes: 5_000_000)
        try site(box, hash("app.example.org"), text: "https://app.example.org/", bytes: 2_000_000)
        try site(box, hash("nowhere.example.net"), text: "pagination\nacmConfiguration\n", bytes: 1_000_000)          // a name that cannot be read
        try site(box, hash("honest.example.com"), text: "https://evil.example.com/ https://other.example.com/", bytes: 1_000_000)   // text of other sites: not proof
        try site(box, hash("noindex.example.com"), bytes: 1_000_000)                                                       // no index file at all
        let sites = ServiceWorkerSites.sites(of: arc, home: box.home)
        XCTAssertEqual(sites.count, 5)
        let hosts = Dictionary(uniqueKeysWithValues: sites.map { ($0.folder, $0.host) })
        XCTAssertEqual(hosts[hash("www.example.com")], "www.example.com")
        XCTAssertEqual(hosts[hash("app.example.org")], "app.example.org")
        XCTAssertEqual(sites.filter { $0.host == nil }.count, 3, "Unreadable, spoofed, and no index are all unknown")
        XCTAssertNil(sites.first { $0.host == "evil.example.com" || $0.host == "other.example.com" }, "A name that does not match its folder is never shown")
        let titles = Set(scanner(box).scanServiceWorkerStorage().map(\.title))
        XCTAssertTrue(titles.contains("Offline website · www.example.com (Arc)"))
        XCTAssertEqual(titles.filter { $0.contains("Unknown site") }.count, 1, "Three unknown sites share one title, so the set has one")
    }

    func testTheNameCanBeInACacheFolderToo() throws {
        let box = try Sandbox()
        let dir = try site(box, hash("deep.example.com"), bytes: 1_000_000)
        try "workbox-https://deep.example.com/".write(to: box.home.appendingPathComponent("\(dir)/cache-1/index.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ServiceWorkerSites.sites(of: arc, home: box.home).first?.host, "deep.example.com")
    }

    func testOnlyTheStartOfAHugeFileIsRead() throws {
        let box = try Sandbox()
        let early = hash("early.example.com"), late = hash("late.example.com")
        try site(box, early, text: "https://early.example.com/" + String(repeating: "x", count: 100_000))
        try site(box, late, text: String(repeating: "x", count: 100_000) + "https://late.example.com/")
        let hosts = Dictionary(uniqueKeysWithValues: ServiceWorkerSites.sites(of: arc, home: box.home).map { ($0.folder, $0.host) })
        XCTAssertEqual(hosts[early], "early.example.com")
        XCTAssertNil(hosts[late] ?? nil, "Behind the read limit: unknown, not slow")
    }

    func testOnlyRealSiteFoldersAreListed() throws {
        let box = try Sandbox()
        try site(box, hash("ok.example.com"), text: "https://ok.example.com/")
        try site(box, "origin1", text: "https://origin1.example.com/")
        try box.file("\(storage)/loose-file", bytes: 2_000_000)
        try box.file("elsewhere/x", bytes: 3_000_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(storage)/\(hash("link.example.com"))"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertEqual(ServiceWorkerSites.sites(of: arc, home: box.home).map(\.host), ["ok.example.com"])
    }

    func testTheProfileIsNamedOnlyWhenThereIsMoreThanOne() throws {
        let box = try Sandbox()
        try site(box, hash("a.example.com"), text: "https://a.example.com/")
        XCTAssertFalse(scanner(box).scanServiceWorkerStorage()[0].location.contains("profile"))
        try site(box, hash("a.example.com"), text: "https://a.example.com/", profile: "Profile 1")
        let all = scanner(box).scanServiceWorkerStorage()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.location.contains("profile") })
        XCTAssertEqual(Set(all.map(\.id)).count, 2, "The same site in two profiles is two items")
    }

    func testTheTextNeverShowsAPathOrAToken() throws {
        let box = try Sandbox()
        try site(box, hash("secret.example.com"), text: "https://secret.example.com/users/me/private?token=SECRET123&k=v", bytes: 1_000_000)
        let f = try XCTUnwrap(scanner(box).scanServiceWorkerStorage().first)
        for text in [f.title, f.location, f.note ?? ""] {
            XCTAssertFalse(text.contains("SECRET123") || text.contains("users/me") || text.contains("token="), text)
        }
        XCTAssertEqual(f.title, "Offline website · secret.example.com (Arc)")
    }

    // MARK: The clean

    func testRemovingOneSiteNeverTouchesAnother() throws {
        let box = try Sandbox()
        let a = try site(box, hash("a.example.com"), text: "https://a.example.com/", bytes: 3_000_000)
        let b = try site(box, hash("b.example.com"), text: "https://b.example.com/", bytes: 2_000_000)
        try box.file("\(support)/Default/Cookies", bytes: 500)
        try box.file("\(support)/Default/Service Worker/Database/000003.log", bytes: 500)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanServiceWorkerStorage().first { $0.title.contains("a.example.com") })
        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertFalse(exists(box, a))
        XCTAssertTrue(exists(box, "\(b)/cache-1/0_0"), "The other site stays")
        XCTAssertTrue(exists(box, "\(support)/Default/Cookies") && exists(box, "\(support)/Default/Service Worker/Database/000003.log"))
        XCTAssertTrue(exists(box, storage), "The CacheStorage folder stays")
        XCTAssertEqual(s.remainingBytes(of: item), 0)
        XCTAssertEqual(s.scanServiceWorkerStorage().count, 1)
    }

    func testAnOpenBrowserBlocksTheItem() throws {
        let box = try Sandbox()
        let a = try site(box, hash("a.example.com"), text: "https://a.example.com/")
        let s = scanner(box)
        let r = cleaner(s, running: [RunningApp(bundleID: "company.thebrowser.Browser", name: "Arc")]).clean(s.scanServiceWorkerStorage())
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.blockedApps, ["Arc"])
        XCTAssertTrue(exists(box, a))
    }

    func testForgedFindingsRemoveNothingElse() throws {
        let box = try Sandbox()
        let a = try site(box, hash("a.example.com"), text: "https://a.example.com/")
        try box.file("\(support)/Default/Cookies", bytes: 500)
        func forged(_ browser: String, _ profile: String, _ folder: String) -> Finding {
            Finding(id: folder, ecosystem: .browsers, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                    action: .removeServiceWorkerSite(browserID: browser, profile: profile, folder: folder))
        }
        let s = scanner(box)
        let report = cleaner(s).clean([forged("arc", "Default", "../Database"), forged("arc", "Default", ".."), forged("arc", "../x", hash("a.example.com")),
                                       forged("arc", "Default", ""), forged("arc", "Default", hash("ghost.example.com")), forged("nope", "Default", hash("a.example.com")),
                                       forged("firefox", "Default", hash("a.example.com")), forged("arc", "Guest Profile", hash("a.example.com")),
                                       forged("arc", "Default", hash("a.example.com").uppercased())])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 9)
        XCTAssertTrue(exists(box, a) && exists(box, "\(support)/Default/Cookies"))
    }

    func testASiteThatBecameALinkAfterThePreviewIsNotFollowed() throws {
        let box = try Sandbox()
        let name = hash("a.example.com")
        try site(box, name, text: "https://a.example.com/")
        try box.file("proj/precious", bytes: 100)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanServiceWorkerStorage().first)
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("\(storage)/\(name)"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(storage)/\(name)"), withDestinationURL: box.home.appendingPathComponent("proj"))
        _ = cleaner(s).clean([item])
        XCTAssertTrue(exists(box, "proj/precious"))
    }

    func testTheDialogKeepsTheSiteByDefault() throws {
        let box = try Sandbox()
        try site(box, hash("a.example.com"), text: "https://a.example.com/")
        let f = try XCTUnwrap(scanner(box).scanServiceWorkerStorage().first)
        XCTAssertEqual(Confirmation.kind(of: f), .serviceWorker)
        XCTAssertTrue(Confirmation.forOne(f, staleDays: 30).cancelIsDefault)
    }
}
