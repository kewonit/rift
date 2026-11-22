import Foundation
import RiftControl
import RiftIPC
import SwiftUI

/// Whether `riftctl` may run commands that read private data or change
/// Rift. Any process running as you can run `riftctl`, so these need the
/// person to turn them on here first. Status, profiles and redacted
/// diagnostics always work.
enum CLIAccess {
    static let storageKey = "cliAccessEnabled"

    static var isAllowed: Bool { UserDefaults.standard.bool(forKey: storageKey) }
}

extension ControlPlaneController {
    /// Connection history for `riftctl history export`.
    func cliHistoryExport(_ request: CLIRelayRequest) async throws -> CLIRelayResponse {
        guard CLIAccess.isAllowed else { throw CLIAccessRefusal.terminalAccessOff }
        guard persistentHistoryEnabled, let history else {
            throw ArchiveControllerError.invalidRelayRequest
        }
        let format: HistoryExportFormat = request.argument == "json" ? .json : .csv
        let data = try await history.exportData(
            format: format, now: Date(),
            maximumBytes: min(HistoryExportCodec.maximumBytes, IPCProtocolLimits.maximumSnapshotBytes)
        )
        let transfer = try await cliTransfers.beginDownload(data: data, now: Date())
        return try CLIRelayResponse(
            summary: "Connection history saved as \(format.rawValue.uppercased())",
            payload: try SecureIPCCodec.encode(transfer)
        )
    }
}

/// Settings › Advanced: the switch for `riftctl` commands that read private
/// data or change Rift.
struct CLIAccessSection: View {
    @AppStorage(CLIAccess.storageKey) private var allowed = false

    var body: some View {
        Section {
            Toggle("Allow access from Terminal", isOn: $allowed)
        } header: {
            Text("Command Line")
        } footer: {
            Text("riftctl can always show status and profiles and save redacted diagnostics. Exporting connection history needs this on, because any app running as you can run riftctl.")
        }
    }
}
