import ArrumatorCore
import Foundation
import Testing

@Suite struct AppVersionTests {
    /// A bundle directory whose Info.plist holds `info`, removed when the test ends.
    private func bundle(_ info: [String: String]) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppVersion-\(UUID().uuidString).bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root), "a directory with Contents/Info.plist opens as a bundle")
        return (bundle, root)
    }

    @Test func aReleaseReportsTheVersionItsInfoPlistCarries() throws {
        let (bundle, root) = try bundle(["CFBundleShortVersionString": "0.1.42"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AppVersion.of(bundle) == "0.1.42", "traces, doctor and --version show the version the release was built as")
    }

    @Test func aBuildWithoutAVersionReportsDevelopment() throws {
        let (bundle, root) = try bundle(["CFBundleIdentifier": "dev.arrumator.test"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AppVersion.of(bundle) == AppVersion.development,
                "a development build of the command carries no Info.plist and must not claim a release version")
    }

    @Test func anEmptyVersionCountsAsNone() throws {
        let (bundle, root) = try bundle(["CFBundleShortVersionString": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AppVersion.of(bundle) == AppVersion.development,
                "an unset MARKETING_VERSION expands to an empty string, which is no version")
    }
}
