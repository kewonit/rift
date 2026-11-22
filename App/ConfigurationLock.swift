import Foundation
import LocalAuthentication
import Observation
import RiftControl
import SwiftUI

/// Locks Rift's configuration until the person unlocks it with Touch ID or
/// their login password, as macOS offers. ⌘L locks. Every change made by
/// hand checks the lock in `ControlPlaneController`, so a page that forgets
/// to disable a control still can't change anything.
@MainActor
@Observable
final class ConfigurationLock {
    static let shared = ConfigurationLock()
    private static let storageKey = "configurationLocked"

    private(set) var state: ConfigurationLockState
    private(set) var isUnlocking = false

    var isLocked: Bool { state.isLocked }

    private init() {
        state = ConfigurationLockState(launchingWithLockEnabled: UserDefaults.standard.bool(forKey: Self.storageKey))
    }

    func lock() {
        state.lock()
        save()
    }

    /// Asks macOS to confirm it's the person, then unlocks. Returns whether
    /// the configuration is unlocked.
    @discardableResult
    func unlock(untilQuit: Bool) async -> Bool {
        guard state.isLocked else { return true }
        guard !isUnlocking else { return false }
        isUnlocking = true
        defer { isUnlocking = false }
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else { return false }
        let confirmed: Bool = await withCheckedContinuation { continuation in
            // macOS answers on its own queue, not the main one.
            context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: ConfigurationLockCopy.unlockReason
            ) { @Sendable success, _ in
                continuation.resume(returning: success)
            }
        }
        guard confirmed else { return false }
        state.unlock(untilQuit: untilQuit)
        save()
        return true
    }

    func permits(_ change: ConfigurationChange) -> Bool { state.permits(change) }

    /// The sentence for a change the lock refused, or nil for other errors.
    static func message(for error: any Error) -> String? {
        error is ConfigurationLockError ? ConfigurationLockCopy.lockedMessage : nil
    }

    private func save() {
        UserDefaults.standard.set(state.isEnabled, forKey: Self.storageKey)
    }
}

extension ControlPlaneController {
    /// Refuses a change made by hand while the configuration is locked, and
    /// says so wherever the person is working.
    func requireUnlocked(_ change: ConfigurationChange = .byHand) throws {
        guard !ConfigurationLock.shared.permits(change) else { return }
        actionResults.post(ConfigurationLockCopy.lockedMessage, tone: .failure)
        throw ConfigurationLockError.locked
    }
}

/// Lock Configuration (⌘L), and the two ways to unlock it.
struct ConfigurationLockCommands: Commands {
    private var lock: ConfigurationLock { .shared }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            if lock.isLocked {
                Button("Unlock Configuration…") { Task { await lock.unlock(untilQuit: false) } }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(lock.isUnlocking)
                Button("Unlock Until Quit…") { Task { await lock.unlock(untilQuit: true) } }
                    .disabled(lock.isUnlocking)
            } else {
                Button("Lock Configuration") { lock.lock() }
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}

/// Says the configuration is locked, with a way to unlock it.
struct ConfigurationLockBanner: View {
    private var lock: ConfigurationLock { .shared }

    var body: some View {
        if lock.isLocked {
            HStack(spacing: RiftDesign.Spacing.s) {
                Label(ConfigurationLockCopy.banner, systemImage: "lock.fill")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: RiftDesign.Spacing.s)
                Menu("Unlock…") {
                    Button("Unlock") { Task { await lock.unlock(untilQuit: false) } }
                    Button("Unlock Until Quit") { Task { await lock.unlock(untilQuit: true) } }
                } primaryAction: {
                    Task { await lock.unlock(untilQuit: false) }
                }
                .fixedSize()
                .disabled(lock.isUnlocking)
                .help("Unlock with Touch ID or your login password")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1))
        }
    }
}
