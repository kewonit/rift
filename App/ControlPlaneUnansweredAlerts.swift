import RiftControl
import RiftIPC
import Foundation

/// Keeps the filter's copy of Settings › Alerts in step with the app's: how
/// long an alert waits, and whether an unanswered connection is blocked. The
/// filter holds it in its policy, so it applies when Rift isn't open.
extension ControlPlaneController {
    static var unansweredAlertSettings: UnansweredAlertSettings {
        let defaults = UserDefaults.standard
        return UnansweredAlertSettings(
            blocks: defaults.bool(forKey: UnansweredAlertSettings.blocksKey),
            storedWaitSeconds: defaults.integer(forKey: UnansweredAlertSettings.waitSecondsKey)
        )
    }

    /// Saves the setting into the configuration when it differs from what's
    /// stored there. Runs after every handshake and every change in Settings,
    /// so it also catches a restore, a reset and a filter update.
    func syncUnansweredAlerts() {
#if DEBUG
        guard !isUIFixture else { return }
#endif
        guard unansweredAlertSync == nil else {
            unansweredAlertSyncPending = true
            return
        }
        unansweredAlertSync = Task { [weak self] in
            repeat {
                self?.unansweredAlertSyncPending = false
                await self?.applyUnansweredAlertSettings()
            } while self?.unansweredAlertSyncPending == true
            self?.unansweredAlertSync = nil
        }
    }

    private func applyUnansweredAlertSettings() async {
        // Without a handshake Rift can't tell an old filter from one it can't
        // reach, and clearing the setting for the second would stop blocking.
        guard case .connected = state, let handshake = lastHandshake, let repository,
              !configurationRecoveryRequired else { return }
        let wanted = Self.unansweredAlertSettings.filterPolicy(
            filterSupportsIt: handshake.protocolRange.maximum.supports(minimum: .extendedPolicy)
        )
        do {
            guard try await repository.currentConfiguration() != nil,
                  try await repository.unansweredAlerts() != wanted else {
                unansweredAlertSyncRetries = 0
                return
            }
            // Automatic: it only keeps the filter in step with a choice already
            // made, so a locked configuration mustn't stop it.
            _ = try await mutateConfiguration(kind: "setUnansweredAlerts", change: .automatic) { draft in
                Self.copy(draft, unansweredAlertChange: .set(wanted))
            }
            unansweredAlertSyncRetries = 0
        } catch {
            // Nothing changed, for instance because a restore is still being
            // applied. Rift answers Block itself while it's open, and tries
            // again shortly, then at the next handshake or change in Settings.
            guard unansweredAlertSyncRetries < Self.maximumUnansweredAlertSyncRetries else { return }
            unansweredAlertSyncRetries += 1
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.syncUnansweredAlerts()
            }
        }
    }

    private static let maximumUnansweredAlertSyncRetries = 6
}
