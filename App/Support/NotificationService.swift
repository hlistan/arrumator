import ArrumatorCore
import Foundation
import Observation
import UserNotifications

/// Whether macOS lets the app show notifications, as Settings › General says under its switches.
enum NotificationPermission: Equatable {
    /// Allowed, in an alert, a banner or quietly.
    case allowed
    /// Not asked yet: the app asks the first time a notification is due, or when a switch is turned on.
    case notAsked
    /// Turned off for the app in System Settings › Notifications.
    case refused
    /// macOS would not let the app ask, as it may not for a build not signed for distribution: the app is not listed in
    /// System Settings › Notifications until it can.
    case unavailable

    /// What macOS says of the app (`UNNotificationSettings.authorizationStatus`), and whether asking failed.
    init(_ status: UNAuthorizationStatus, askingFailed: Bool) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .allowed
        case .denied: self = .refused
        case .notDetermined: self = askingFailed ? .unavailable : .notAsked
        @unknown default: self = askingFailed ? .unavailable : .notAsked
        }
    }
}

/// Posts user notifications for new filings and documents needing review, as configured in settings, and says whether
/// macOS lets it (`permission`), rather than giving up without a word.
@Observable
final class NotificationService {
    /// What macOS last said; read again when Settings shows the switches, and after the app asks.
    private(set) var permission = NotificationPermission.notAsked
    /// Asking failed: macOS would not let the app ask (`UNUserNotificationCenter.requestAuthorization`), or did not
    /// answer in time.
    private var askingFailed = false
    /// The asking macOS has not answered yet: one at a time, however often a notification is due meanwhile.
    private var asking: Task<Void, Never>?

    /// Reads whether macOS lets the app notify, without asking.
    func readPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let read = NotificationPermission(status, askingFailed: askingFailed)
        guard read != permission else { return }
        permission = read
        // Once, when it changes: why nothing is notified is in the log too, without anything of a document.
        switch read {
        case .refused: Log.warning(.ui, "Notifications are turned off for the app in System Settings")
        case .unavailable: Log.warning(.ui, "macOS would not let the app ask to show notifications")
        case .allowed, .notAsked: break
        }
    }

    /// Asks macOS to let the app notify, as it shows the user the first time; afterwards it answers at once. macOS may
    /// never answer, as for a build not signed for distribution, so the app waits `timeout` seconds
    /// (`interface.notificationAskTimeout`) and then takes it that macOS would not let it ask; an answer that comes later
    /// still counts. Why it cannot ask is logged, and Settings says so.
    func requestAuthorization(timeout: Double) async {
        // Still unanswered after a wait: not waited for again until macOS answers.
        guard !(askingFailed && asking != nil) else { return }
        let asking = asking ?? Task {
            await ask()
            self.asking = nil
        }
        self.asking = asking
        let answered = await Self.finishes(asking, within: .seconds(timeout))
        // A wait cut short, as when the app quits, says nothing of macOS.
        guard !Task.isCancelled else { return }
        if !answered {
            if !askingFailed { Log.error(.ui, "Asking to show notifications got no answer from macOS in time", ["seconds": "\(timeout)"]) }
            askingFailed = true
        }
        await readPermission()
    }

    /// Whether `work` finishes within `timeout`; it goes on either way, as macOS's asking cannot be stopped.
    private static func finishes(_ work: Task<Void, Never>, within timeout: Duration) async -> Bool {
        let (finished, answer) = AsyncStream.makeStream(of: Bool.self)
        let waiting = [Task { await work.value; answer.yield(true) },
                       Task { try? await Task.sleep(for: timeout); answer.yield(false) }]
        defer { waiting.forEach { $0.cancel() } }
        for await first in finished { return first }
        return false
    }

    /// Asks macOS once, and takes in its answer.
    private func ask() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            // macOS may answer "not granted" without an error and still hold no answer of the user's, as for a build
            // not signed for distribution, which it never lists in System Settings › Notifications: that is no asking.
            let settled = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus != .notDetermined
            let unanswered = !granted && !settled
            if unanswered && !askingFailed { Log.error(.ui, "Asking to show notifications got no answer from macOS") }
            askingFailed = unanswered
        } catch {
            if !askingFailed { Log.error(.ui, "Asking to show notifications failed", ["error": error.localizedDescription]) }
            askingFailed = true
        }
        await readPermission()
    }

    /// Notifies of the filings and the documents waiting for the user that came after `previous`, as the settings ask.
    func announce(_ events: [EventRecord], previous: [EventRecord], settings: AppSettings?, askTimeout: Double) async {
        guard let settings, let newest = previous.first?.id else { return }
        let wanted = events.filter { event in
            (event.id ?? 0) > newest
                && ((event.kind == .filed && settings.notifyOnFiled) || (event.kind == .needsReview && settings.notifyOnReview))
        }
        guard !wanted.isEmpty else { return }
        if permission != .allowed { await requestAuthorization(timeout: askTimeout) }
        guard permission == .allowed else { return }
        for event in wanted {
            let content = UNMutableNotificationContent()
            content.title = event.kind == .filed ? Wording.notifyFiled : Wording.notifyReview
            content.body = event.summary
            do {
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "event-\(event.id ?? 0)", content: content, trigger: nil))
            } catch {
                Log.error(.ui, "A notification could not be shown", ["error": error.localizedDescription])
            }
        }
    }
}
