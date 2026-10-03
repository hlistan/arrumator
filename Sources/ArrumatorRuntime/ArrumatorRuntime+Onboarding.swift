import ArrumatorCore
import ArrumatorExtract
import Foundation
import Synchronization

extension ArrumatorRuntime {
    /// Ends the app's onboarding, the archive's first setup: makes the archive's folder when it is not there, then records
    /// that onboarding is done. With a switch to a folder that is not there, the only time the app makes an archive's
    /// folder, as both are what the user asks: at any other launch, one that is not there is away
    /// (`RecordsError.archiveNotThere`), whatever its index holds, as a new index looks the same whether the archive is
    /// new or away. A folder that cannot be made, as on a disk not connected under a mount point the user cannot write
    /// in, is left away, which opening it then says.
    public func finishOnboarding() async throws {
        if await !settings.current.onboardingCompleted, !records.archiveIsThere {
            do {
                try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            } catch {
                Log.warning(.app, "The archive's folder could not be made; it is away", ["archive": archive.path, "error": error.localizedDescription])
            }
        }
        try await settingsActions.change { $0.onboardingCompleted = true }
    }
}
