import RiftCore
import SwiftUI

struct FilterStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: FilterLifecycleController
    @Bindable var controlPlane: ControlPlaneController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.initialStatusResolved ? controller.title : "Checking network filter…")
                .font(.title3.weight(.semibold))
            Text(controller.initialStatusResolved
                ? controller.guidance
                : "Rift is asking macOS for the installed filter state.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let issue = controlPlane.startupIssue {
                GroupBox("Configuration recovery required") {
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
                    Button("Retry") {
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
                    Text("Rift never reports filtering or activity while macOS has disabled the extension.")
                    Button("Copy Redacted Health") {
                        controller.copyRedactedDiagnostics()
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}
