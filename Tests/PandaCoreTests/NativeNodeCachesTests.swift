import XCTest
@testable import PandaCore

final class NativeNodeCachesTests: XCTestCase {
    func testElectronAndNodeGypCachesAreSafeAndRemoved() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/electron/abc/electron-v30-darwin-arm64.zip", bytes: 3_000_000)
        try box.file("Library/Caches/node-gyp/20.1.0/include/node/node.h", bytes: 3_000_000)
        try box.file(".electron/keep.zip", bytes: 2_000_000)   // too shallow for the path guard: never a target
        try box.file("Library/Caches/electron-other/keep", bytes: 3_000_000)
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let found = s.scan().findings.filter { $0.id.hasPrefix("electron.cache") || $0.id.hasPrefix("nodegyp.cache") }
        XCTAssertEqual(Set(found.map(\.title)), ["Electron downloads", "node-gyp headers"])
        XCTAssertEqual(found.count, 2, "One item for each folder")
        XCTAssertTrue(found.allSatisfy { $0.tier == .safe && $0.rebuild == .download && $0.bytes >= 2_000_000 })
        let r = Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:)).clean(found)
        XCTAssertEqual(r.removed, 2)
        for gone in ["Library/Caches/electron/abc", "Library/Caches/node-gyp/20.1.0"]  {
            XCTAssertFalse(FileManager.default.fileExists(atPath: box.home.appendingPathComponent(gone).path), gone)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent(".electron/keep.zip").path), "Not scanned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Library/Caches/electron-other/keep").path),
                      "A similar name stays")
    }
}
