import RiftFilterRuntime
import Foundation

enum RuntimeEnvironment {
    static let prompts = PromptQueue()
    static let events = RuntimeEventRing()
    static let notifications = EphemeralNotificationQueue()
    static let reloads = PolicyReloadSignal()
    static let policy: PolicyRuntime = {
        let rootURL: URL?
        if let group = Bundle.main.object(
            forInfoDictionaryKey: "RiftAppGroupIdentifier"
        ) as? String,
           !group.isEmpty,
           let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
           ) {
            rootURL = container.appendingPathComponent("RiftFilterState", isDirectory: true)
        } else {
            rootURL = nil
        }
        return PolicyRuntime(
            rootURL: rootURL,
            prompts: prompts,
            events: events,
            notifications: notifications,
            reloads: reloads
        )
    }()
}
