import Foundation
import SystemConfiguration

final class ConsoleSessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "io.rift.firewall.console-session")
    private var store: SCDynamicStore?
    private var uid: UInt32?

    init() {
        refresh()
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "io.rift.firewall.console-session" as CFString,
            { _, _, info in
                guard let info else { return }
                Unmanaged<ConsoleSessionTracker>.fromOpaque(info)
                    .takeUnretainedValue()
                    .refresh()
            },
            &context
        ) else { return }
        let key = SCDynamicStoreKeyCreateConsoleUser(nil)
        guard SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil),
              SCDynamicStoreSetDispatchQueue(store, callbackQueue) else { return }
        self.store = store
    }

    var currentUID: UInt32? {
        lock.withLock { uid }
    }

    private func refresh() {
        var value: uid_t = 0
        var gid: gid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &value, &gid) as String?
        let resolved: UInt32? = if let name,
                                   name != "loginwindow",
                                   value != 0 {
            UInt32(value)
        } else {
            nil
        }
        lock.withLock { uid = resolved }
    }
}
