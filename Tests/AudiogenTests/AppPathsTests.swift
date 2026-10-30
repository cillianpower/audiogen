import XCTest
import Foundation
@testable import Audiogen

final class AppPathsTests: XCTestCase {
    private func fixture() throws -> (home: URL, defaults: UserDefaults, suite: String) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let suite = "AudiogenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (home, defaults, suite)
    }
    func testSupportRootStaysOnLegacyFolderAfterNewerFolderAppears() throws {
        let (home, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/GenerativeAudio"), withIntermediateDirectories: true)
        func resolve() -> URL {
            AppPaths.stickyDirectory(defaults: defaults, key: "supportDirectory", home: home,
                                     path: "Library/Application Support/Audiogen",
                                     legacy: "Library/Application Support/GenerativeAudio")
        }
        XCTAssertEqual(resolve().lastPathComponent, "GenerativeAudio")
        // A later launch that finds the newer folder must keep using the recorded root.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Audiogen"), withIntermediateDirectories: true)
        XCTAssertEqual(resolve().lastPathComponent, "GenerativeAudio")
        XCTAssertEqual(defaults.string(forKey: "supportDirectory"), resolve().path)
    }
    func testSupportRootPrefersCurrentFolderWhenNoLegacyInstallExists() throws {
        let (home, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        let chosen = AppPaths.stickyDirectory(defaults: defaults, key: "supportDirectory", home: home,
                                              path: "Library/Application Support/Audiogen",
                                              legacy: "Library/Application Support/GenerativeAudio")
        XCTAssertEqual(chosen.lastPathComponent, "Audiogen")
        XCTAssertEqual(defaults.string(forKey: "supportDirectory"), chosen.path)
    }
}
