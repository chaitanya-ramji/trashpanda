import XCTest
@testable import PandaCore

/// #32: check for updates. Once a day, off by default for nobody who turns it off, and it never installs anything.
final class UpdateCheckTests: XCTestCase {
    private func release(_ tag: String, pre: Bool = false, draft: Bool = false, url: String? = nil) -> [String: Any] {
        ["tag_name": tag, "prerelease": pre, "draft": draft,
         "html_url": url ?? "https://github.com/chaitanya-ramji/trashpanda/releases/tag/\(tag)", "name": "x", "body": "text"]
    }
    private func json(_ list: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: list) }
    private func fetch(_ list: [[String: Any]], status: Int = 200) -> (URLRequest) -> (Data?, Int) { { _ in (self.json(list), status) } }
    private func defaults() -> UserDefaults {
        let name = "trashpanda-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Versions

    func testTagsAndOrder() {
        XCTAssertEqual(UpdateCheck.version(fromTag: "v0.4.0-beta.5"), "0.4.0-beta.5")
        XCTAssertEqual(UpdateCheck.version(fromTag: "0.4.0"), "0.4.0")
        for bad in ["", "latest", "v1", "v1.2", "release-1.0.0", "v1.2.3.4", "v1.2.3\n", "nightly"] { XCTAssertNil(UpdateCheck.version(fromTag: bad), bad) }
        XCTAssertTrue(UpdateCheck.isNewer("0.4.0-beta.6", than: "0.4.0-beta.5"))
        XCTAssertTrue(UpdateCheck.isNewer("0.4.0-beta.10", than: "0.4.0-beta.9"), "By number, not by text")
        XCTAssertTrue(UpdateCheck.isNewer("0.4.0", than: "0.4.0-beta.5"), "The release is newer than its betas")
        XCTAssertTrue(UpdateCheck.isNewer("0.5.0-beta.1", than: "0.4.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.4.0-beta.5", than: "0.4.0-beta.5"))
        XCTAssertFalse(UpdateCheck.isNewer("0.4.0-beta.4", than: "0.4.0-beta.5"))
    }

    // MARK: What is offered

    func testANewerBetaIsOfferedToABetaUser() throws {
        let data = json([release("v0.4.0-beta.6", pre: true), release("v0.4.0-beta.5", pre: true), release("v0.1.0")])
        let r = try XCTUnwrap(UpdateCheck.available(from: data, current: "0.4.0-beta.5"))
        XCTAssertEqual(r.version, "0.4.0-beta.6")
        XCTAssertTrue(r.isPrerelease)
    }

    func testTheNewestIsFoundWhateverTheOrder() throws {
        let data = json([release("v0.4.0-beta.2", pre: true), release("v0.4.0-beta.9", pre: true), release("v0.4.0-beta.10", pre: true), release("v0.1.0")])
        XCTAssertEqual(UpdateCheck.available(from: data, current: "0.4.0-beta.1")?.version, "0.4.0-beta.10")
    }

    func testAStableUserDoesNotSeeBetas() throws {
        let data = json([release("v0.5.0-beta.1", pre: true), release("v0.4.0-beta.5", pre: true), release("v0.1.0")])
        XCTAssertNil(UpdateCheck.available(from: data, current: "0.1.0"), "Only a stable release counts")
        let withStable = json([release("v0.5.0-beta.1", pre: true), release("v0.2.0"), release("v0.1.0")])
        XCTAssertEqual(UpdateCheck.available(from: withStable, current: "0.1.0")?.version, "0.2.0")
    }

    func testAReleaseFlaggedAsPrereleaseIsOneEvenWithAPlainTag() {
        let data = json([release("v0.9.0", pre: true)])
        XCTAssertNil(UpdateCheck.available(from: data, current: "0.1.0"), "GitHub says that it is a pre-release")
        XCTAssertNotNil(UpdateCheck.available(from: data, current: "0.4.0-beta.5"))
    }

    func testTheSameOrAnOlderVersionIsNotAnUpdate() {
        let data = json([release("v0.4.0-beta.5", pre: true), release("v0.4.0-beta.4", pre: true)])
        XCTAssertNil(UpdateCheck.available(from: data, current: "0.4.0-beta.5"))
        XCTAssertNil(UpdateCheck.available(from: data, current: "0.4.0"))
        XCTAssertNil(UpdateCheck.available(from: data, current: "9.9.9"))
    }

    func testDraftsAndOddEntriesAreIgnored() {
        let data = json([release("v9.0.0", draft: true), release("not-a-version"), release("v0.2.0", url: "https://evil.example.com/chaitanya-ramji/trashpanda/releases/tag/v0.2.0"),
                         release("v0.3.0", url: "http://github.com/chaitanya-ramji/trashpanda/releases/tag/v0.3.0"),
                         release("v0.3.1", url: "https://github.com/other/repo/releases/tag/v0.3.1"), ["tag_name": 5], ["html_url": "x"]])
        XCTAssertNil(UpdateCheck.available(from: data, current: "0.1.0"))
    }

    func testOnlyAPageInThisRepositoryIsTrusted() {
        func t(_ s: String) -> Bool { UpdateCheck.isTrustedReleaseURL(URL(string: s)!) }
        XCTAssertTrue(t("https://github.com/chaitanya-ramji/trashpanda/releases/tag/v0.4.0-beta.5"))
        for bad in ["http://github.com/chaitanya-ramji/trashpanda/releases/tag/v1.0.0", "https://github.com.evil.com/chaitanya-ramji/trashpanda/releases/tag/v1",
                    "https://evil.com/chaitanya-ramji/trashpanda/releases/tag/v1", "https://github.com/chaitanya-ramji/other/releases/tag/v1",
                    "https://github.com/chaitanya-ramji/trashpanda-x/releases/tag/v1", "https://user@github.com/chaitanya-ramji/trashpanda/releases/tag/v1",
                    "https://github.com:8443/chaitanya-ramji/trashpanda/releases/tag/v1", "https://github.com/chaitanya-ramji/trashpanda/issues/1",
                    "file:///etc/passwd", "https://github.com/chaitanya-ramji/trashpanda/releases", "javascript:alert(1)"] {
            XCTAssertFalse(t(bad), bad)
        }
    }

    func testABuildWithoutAVersionChecksNothing() {
        let data = json([release("v9.0.0")])
        XCTAssertNil(UpdateCheck.available(from: data, current: "dev"))
        var asked = 0
        let outcome = UpdateCheck.check(current: "dev") { _ in asked += 1; return (data, 200) }
        XCTAssertEqual(asked, 0, "No request is sent")
        if case .failed = outcome {} else { XCTFail("\(outcome)") }
    }

    // MARK: The check

    func testTheOutcomes() {
        let list = [release("v0.4.0-beta.6", pre: true)]
        if case .newer(let r) = UpdateCheck.check(current: "0.4.0-beta.5", fetch: fetch(list)) { XCTAssertEqual(r.version, "0.4.0-beta.6") } else { XCTFail("newer") }
        XCTAssertEqual(UpdateCheck.check(current: "0.4.0-beta.6", fetch: fetch(list)), .upToDate)
        XCTAssertEqual(UpdateCheck.check(current: "0.4.0-beta.5", fetch: fetch([])), .upToDate)
        for status in [0, 403, 404, 500] {
            if case .failed = UpdateCheck.check(current: "0.4.0", fetch: fetch(list, status: status)) {} else { XCTFail("\(status)") }
        }
        if case .failed = UpdateCheck.check(current: "0.4.0", fetch: { _ in (Data("not json".utf8), 200) }) {} else { XCTFail("bad json") }
        if case .failed = UpdateCheck.check(current: "0.4.0", fetch: { _ in (Data("{\"message\": \"rate limit\"}".utf8), 200) }) {} else { XCTFail("an object is not a list") }
        if case .failed = UpdateCheck.check(current: "0.4.0", fetch: { _ in (nil, 200) }) {} else { XCTFail("no data") }
    }

    func testAHugeAnswerIsRefused() {
        let big = Data(repeating: 0x20, count: UpdateCheck.maximumBytes + 10)
        if case .failed = UpdateCheck.check(current: "0.4.0", fetch: { _ in (big, 200) }) {} else { XCTFail("too big") }
        XCTAssertNil(UpdateCheck.newestEligible(from: big, current: "0.4.0"))
    }

    func testTheCheckWorksWithTheNewAndTheOldVersion() {
        let list = [release("v0.8.0-beta.2", pre: true), release("v0.4.0-beta.6", pre: true), release("v0.7.0")]
        if case .newer(let r) = UpdateCheck.check(current: "0.8.0-beta.1", fetch: fetch(list)) { XCTAssertEqual(r.version, "0.8.0-beta.2") } else { XCTFail("new beta") }
        if case .newer(let r) = UpdateCheck.check(current: "0.4.0-beta.6", fetch: fetch(list)) { XCTAssertEqual(r.version, "0.8.0-beta.2") } else { XCTFail("old beta") }
        XCTAssertEqual(UpdateCheck.check(current: "0.8.0-beta.2", fetch: fetch(list)), .upToDate)
    }

    // MARK: A failed check is not a check

    func testAFailedCheckDoesNotChangeTheStoredDate() {
        let p = UpdatePreferences(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        p.markChecked(t0)
        p.markFailed(t0.addingTimeInterval(90_000))
        XCTAssertEqual(p.lastCheck, t0)
    }

    func testAfterAFailureTheNextTryIsAfterOneHourAndAtMostThreePerDay() {
        let p = UpdatePreferences(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(p.isDue(now: t0))
        p.markFailed(t0)
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(3_599)))
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(3_600)))
        p.markFailed(t0.addingTimeInterval(3_600))
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(7_200)))
        p.markFailed(t0.addingTimeInterval(7_200))
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(10_800)), "Three failures in one day: stop")
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(86_399)))
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(86_400)), "The next day")
    }

    func testAGoodAnswerClearsTheFailures() {
        let p = UpdatePreferences(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 { p.markFailed(t0.addingTimeInterval(Double(i) * 3_600)) }
        p.markChecked(t0.addingTimeInterval(10_000))
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(20_000)), "A good check counts: wait a day")
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(10_000 + 86_400)))
    }

    func testAFailedFetchResultIsAnError() {
        if case .failed = UpdateCheck.check(current: "0.4.0", fetch: { _ in (nil, UpdateCheck.tooLargeStatus) }) {} else { XCTFail("too large") }
    }

    // MARK: The size is checked while the answer arrives

    func testAnAnswerOfTwoMegabytesIsCancelledWhileItArrives() {
        final class FakeServer: URLProtocol {
            nonisolated(unsafe) static var sent = 0
            nonisolated(unsafe) static var stopped = false
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let part = Data(repeating: 0x20, count: 100_000)
                // One part every 50 ms, so that the cancel has time to arrive.
                for i in 0..<20 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05 * Double(i)) { [self] in
                        guard !Self.lock.withLock({ Self.stopped }) else { return }
                        Self.lock.withLock { Self.sent += part.count }
                        client?.urlProtocol(self, didLoad: part)
                        if i == 19 { client?.urlProtocolDidFinishLoading(self) }
                    }
                }
            }
            override func stopLoading() { Self.lock.withLock { Self.stopped = true } }
            static let lock = NSLock()
        }
        FakeServer.sent = 0
        FakeServer.stopped = false
        let configuration = UpdateCheck.makeConfiguration()
        configuration.protocolClasses = [FakeServer.self]
        let (data, status) = UpdateCheck.fetchLimited(UpdateCheck.request(), configuration: configuration, maximumBytes: UpdateCheck.maximumBytes)
        XCTAssertNil(data)
        XCTAssertEqual(status, UpdateCheck.tooLargeStatus)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(FakeServer.lock.withLock { FakeServer.stopped }, "The task was cancelled")
        XCTAssertLessThan(FakeServer.sent, 2_000_000, "Not the whole 2 MB was read")
        if case .failed = UpdateCheck.check(current: "0.4.0", fetch: { _ in (data, status) }) {} else { XCTFail("an error") }
    }

    // MARK: Privacy

    func testTheRequestIsOnlyTheRequestItself() throws {
        let r = UpdateCheck.request()
        XCTAssertEqual(r.url, UpdateCheck.apiURL)
        XCTAssertEqual(r.url?.host, "api.github.com")
        XCTAssertNil(r.url?.query?.replacingOccurrences(of: "per_page=15", with: "").nilIfEmpty, "No other parameter")
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertNil(r.httpBody)
        XCTAssertNil(r.httpBodyStream)
        XCTAssertFalse(r.httpShouldHandleCookies)
        XCTAssertEqual(Set((r.allHTTPHeaderFields ?? [:]).keys), ["Accept", "User-Agent"], "Two plain headers and nothing else")
        XCTAssertEqual(r.allHTTPHeaderFields?["User-Agent"], "TrashPanda", "No version, no id, no system name")
        XCTAssertNil(r.allHTTPHeaderFields?["Authorization"])
    }

    func testTheSessionKeepsNothing() {
        let c = UpdateCheck.makeSession().configuration
        XCTAssertNil(c.httpCookieStorage)
        XCTAssertFalse(c.httpShouldSetCookies)
        XCTAssertNil(c.urlCache)
        XCTAssertNil(c.urlCredentialStorage)
        XCTAssertFalse(c.waitsForConnectivity)
    }

    func testNothingInTheCodeDownloadsOrInstalls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var checked = 0
        for name in ["PandaCore/UpdateCheck.swift", "TrashPanda/UpdateController.swift"] {
            for line in try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                checked += 1
                for banned in ["downloadTask", "download(", "NSWorkspace.shared.openApplication", "Process()", "installer", "hdiutil", "unzip", ".dmg", "browser_download_url"] {
                    XCTAssertFalse(t.contains(banned), "\(name): \(t)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 80)
    }

    // MARK: Once a day, and the switch

    func testTheFirstCheckIsDueAndTheNextOneIsADayLater() {
        let p = UpdatePreferences(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(p.isDue(now: t0), "Never checked")
        p.markChecked(t0)
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(1)))
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(23 * 3_600)))
        XCTAssertFalse(p.isDue(now: t0.addingTimeInterval(86_399)))
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(86_400)))
        XCTAssertTrue(p.isDue(now: t0.addingTimeInterval(3 * 86_400)))
    }

    func testAClockThatWentBackIsDue() {
        let p = UpdatePreferences(defaults: defaults())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        p.markChecked(t0.addingTimeInterval(10 * 86_400))
        XCTAssertTrue(p.isDue(now: t0), "The last check is in the future, so it cannot be trusted")
    }

    func testTheCheckCanBeTurnedOff() {
        let d = defaults()
        let p = UpdatePreferences(defaults: d)
        XCTAssertTrue(p.isEnabled, "On by default")
        p.isEnabled = false
        XCTAssertFalse(UpdatePreferences(defaults: d).isEnabled, "The choice is kept")
        XCTAssertFalse(p.isDue(now: Date()), "Never due when it is off")
        p.markChecked(Date(timeIntervalSince1970: 0))
        XCTAssertFalse(p.isDue(now: Date()), "Even a year later")
        p.isEnabled = true
        XCTAssertTrue(p.isDue(now: Date()))
    }

    func testADamagedSettingFallsBackToOn() {
        let d = defaults()
        d.set("maybe", forKey: UpdatePreferences.enabledKey)
        XCTAssertFalse(UpdatePreferences(defaults: d).isEnabled, "A value that is not a yes is read as no by UserDefaults, and that is the safe side for privacy")
        d.set("junk", forKey: UpdatePreferences.lastCheckKey)
        XCTAssertNil(UpdatePreferences(defaults: d).lastCheck)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
