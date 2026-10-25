import RiftCore
import SwiftUI

struct FilterStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: FilterLifecycleController
    @Bindable var controlPlane: ControlPlaneController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.initialStatusResolved ? controller.title : "Checking the network filter…")
                .font(.title3.weight(.semibold))
            Text(controller.initialStatusResolved
                ? controller.guidance
                : "Rift is checking the filter’s status with macOS.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let issue = controlPlane.startupIssue {
                GroupBox("Rift found a problem") {
                    Text(issue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if controller.initialStatusResolved, case .notInstalled = controller.state {
                    Button("Install and Enable") {
                        controller.installAndEnable()
                    }
                    .disabled(controller.operationInProgress)
                    .keyboardShortcut(.defaultAction)
                }

                if controller.shouldOfferRetry {
                    Button("Try Again") {
                        controller.retrySetup()
                    }
                }

                if controller.initialStatusResolved && controller.shouldOfferSettings {
                    Button("Open System Settings") {
                        controller.openSystemSettings()
                    }
                }

                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            DisclosureGroup("Troubleshooting") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("While the filter is turned off in macOS, Rift can’t filter connections or show activity.")
                    Button("Copy Status Report") {
                        controller.copyRedactedDiagnostics()
                    }
                    .help("Copy a short status report for troubleshooting. It doesn’t include personal details.")
                }
                .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}
