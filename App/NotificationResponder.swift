import AppKit
import Foundation
import UserNotifications

/// Takes a click on a notification to the Map, and to the connection itself
/// when it's still there.
@MainActor
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let rowIDKey = "rowID"
    private weak var session: AppSession?

    init(session: AppSession) {
        self.session = session
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rowID = response.notification.request.content.userInfo[Self.rowIDKey] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            self?.session?.requestedMonitorEventID = rowID
            self?.session?.destination = .liveMap
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let url = URL(string: "rift://map") { NSWorkspace.shared.open(url) }
        }
    }
}
