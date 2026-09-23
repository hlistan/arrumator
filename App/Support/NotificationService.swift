import ArrumatorCore
import Foundation
import UserNotifications

/// Posts user notifications for new filings and documents needing review, as configured in settings.
final class NotificationService {
    private var authorized = false

    func requestAuthorization() async {
        authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func announce(_ events: [EventRecord], previous: [EventRecord], settings: AppSettings?) async {
        guard let settings, let newest = previous.first?.id else { return }
        let fresh = events.filter { ($0.id ?? 0) > newest }
        guard !fresh.isEmpty else { return }
        if !authorized { await requestAuthorization() }
        guard authorized else { return }
        for event in fresh {
            let wanted = (event.kind == .filed && settings.notifyOnFiled) || (event.kind == .needsReview && settings.notifyOnReview)
            guard wanted else { continue }
            let content = UNMutableNotificationContent()
            content.title = event.kind == .filed ? "Filed" : "Needs your review"
            content.body = event.summary
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "event-\(event.id ?? 0)", content: content, trigger: nil))
        }
    }
}
