import Foundation

/// Whether Rift's configuration can be changed. Locking stops changes to
/// rules, profiles, modes and settings until the person unlocks with Touch ID
/// or their login password. The lock stays on across launches; Unlock Until
/// Quit lifts it only until Rift quits.
///
/// The lock guards against changes made through Rift's own windows, menus
/// and `riftctl`, such as by someone else at the Mac. It isn't a defence
/// against software already running as the person, which can change Rift's
/// files directly.
public struct ConfigurationLockState: Sendable, Hashable {
    /// The person locked the configuration.
    public private(set) var isEnabled: Bool
    /// Unlocked for this run of Rift only.
    public private(set) var isUnlockedUntilQuit: Bool

    public var isLocked: Bool { isEnabled && !isUnlockedUntilQuit }

    /// How Rift starts: locked if it was locked, whatever Unlock Until Quit said.
    public init(launchingWithLockEnabled enabled: Bool) {
        isEnabled = enabled
        isUnlockedUntilQuit = false
    }

    public mutating func lock() {
        isEnabled = true
        isUnlockedUntilQuit = false
    }

    /// Unlock turns the lock off. Unlock Until Quit keeps it on for the next
    /// launch.
    public mutating func unlock(untilQuit: Bool) {
        if untilQuit {
            isUnlockedUntilQuit = isEnabled
        } else {
            isEnabled = false
            isUnlockedUntilQuit = false
        }
    }

    /// Which changes still happen while locked: the ones the person set up
    /// to happen on their own, such as a subscription update or switching
    /// profiles when the Mac joins a network. Everything someone does by hand,
    /// including from the menu bar or `riftctl`, waits for an unlock.
    public func permits(_ change: ConfigurationChange) -> Bool {
        change == .automatic || !isLocked
    }
}

public enum ConfigurationChange: Sendable, Hashable {
    /// A change someone asked for: in a window, the menu bar, an alert's
    /// lasting answer, a notification, or `riftctl`.
    case byHand
    /// A change the person set up earlier to happen by itself.
    case automatic
}

public enum ConfigurationLockError: Error, Sendable, Equatable {
    case locked
}

public enum ConfigurationLockCopy {
    public static let lockedMessage =
        String(localized: "Rift’s configuration is locked. Choose Unlock Configuration… (⌘L) in the Rift menu to make changes.", bundle: .module)
    public static let unlockReason = String(
        localized: "unlock Rift’s rules and settings", bundle: .module,
        comment: "Touch ID reason; macOS shows it after “Rift is trying to”"
    )
    public static let banner =
        String(localized: "The configuration is locked. Rules, profiles, modes and settings can’t be changed until you unlock it. Alerts can still be answered once.", bundle: .module)
}
