import Foundation

/// The version a build reports, read the same way by the app and the `arrumator` command: `CFBundleShortVersionString`
/// from the app's Info.plist, or from the Info.plist a release links into the executable's `__TEXT,__info_plist`
/// section (`scripts/release.sh`). A development build of the command has none and reports `development`.
public enum AppVersion {
    static let infoKey = "CFBundleShortVersionString"
    public static let development = "dev"

    public static func of(_ bundle: Bundle) -> String {
        guard let version = bundle.object(forInfoDictionaryKey: infoKey) as? String, !version.isEmpty else {
            return development
        }
        return version
    }
}
