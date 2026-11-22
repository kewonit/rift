import Foundation
import RiftControl
import RiftCore
import RiftIPC
import UserNotifications

/// Notification buttons: Allow or Block a connection no rule decided, and
/// choose a profile for a network Rift hasn't seen before.
enum NotificationActions {
    static let undecidedCategory = "rift.undecided"
    static let newNetworkCategory = "rift.newNetwork"
    static let allow = "rift.allow"
    static let block = "rift.block"
    static let useCurrentProfile = "rift.network.useCurrent"
    static let chooseProfile = "rift.network.choose"
    static let eventKey = "event"
    static let networkKey = "network"

    static func register() {
        let undecided = UNNotificationCategory(
            identifier: undecidedCategory,
            actions: [
                UNNotificationAction(identifier: allow, title: String(localized: "Allow"), options: []),
                UNNotificationAction(identifier: block, title: String(localized: "Block"), options: [.destructive]),
            ],
            intentIdentifiers: []
        )
        let network = UNNotificationCategory(
            identifier: newNetworkCategory,
            actions: [
                UNNotificationAction(identifier: useCurrentProfile, title: String(localized: "Use Current Profile Here"), options: []),
                UNNotificationAction(identifier: chooseProfile, title: String(localized: "Choose…"), options: [.foreground]),
            ],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([undecided, network])
    }

    /// The connection a notification's buttons act on. It travels with the
    /// notification, so the buttons work after the connection has left the
    /// Map, and it never leaves the Mac.
    static func encode(_ event: RuntimeEvent) -> Data? {
        try? CanonicalPolicyJSON.encoder().encode(event)
    }

    static func event(from data: Data?) -> RuntimeEvent? {
        data.flatMap { try? CanonicalPolicyJSON.decoder().decode(RuntimeEvent.self, from: $0) }
    }
}
