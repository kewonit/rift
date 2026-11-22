import RiftControl
import RiftCore
import SwiftUI

/// The last step of setup: how Rift should behave, and the two choices that
/// decide what the first week is like. Allow and Watch keeps a week of
/// history, so there is something to review; Ask Me starts with Apple's own
/// services allowed, so there are fewer questions.
struct SetupChoiceSection: View {
    /// How long setup keeps history. Settings › History allows 1 to 30 days.
    static let historyDays = 7

    @Bindable var session: AppSession
    let finish: () -> Void
    @State private var choice: OperationMode = .silentAllow
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var keepsHistory = true
    @State private var allowsAppleServices = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: RiftDesign.Spacing.s) {
                Text("How should Rift handle new connections?")
                    .font(.headline)
                Text("You can change this at any time.")
                    .foregroundStyle(.secondary)
                option(
                    .silentAllow,
                    badge: "Recommended",
                    detail: "See what’s connecting first, and block anything you choose from the Map. Nothing is blocked until you say so."
                )
                option(
                    .alert,
                    detail: "Rift asks each time an app connects somewhere new, so expect many questions at first. Rift has to stay open to ask."
                )
            }
            .padding(.vertical, RiftDesign.Spacing.xs)
            Toggle("Open Rift at login", isOn: $opensAtLogin)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Keep \(Self.historyDays) days of connection history on this Mac", isOn: $keepsHistory)
                Text("So you can review what connected. Older entries delete themselves, and nothing leaves this Mac. You can change this in Settings › History.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Allow Apple system services", isOn: $allowsAppleServices)
                Text("Adds the macOS Services group, which lets Apple’s own services reach Apple’s servers, so Rift asks about them less. You can turn it off in Rules.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let failure {
                    Text(failure).foregroundStyle(Color(nsColor: .systemOrange))
                }
                Spacer()
                Button("Done", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
        }
        .onChange(of: choice) { _, value in
            if value == .alert { opensAtLogin = true }
            keepsHistory = value == .silentAllow
            allowsAppleServices = value == .alert
        }
    }

    private func option(_ mode: OperationMode, badge: String? = nil, detail: String) -> some View {
        Button { choice = mode } label: {
            HStack(alignment: .firstTextBaseline, spacing: RiftDesign.Spacing.s) {
                Image(systemName: choice == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == mode ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: RiftDesign.Spacing.s) {
                        Text(mode.displayName)
                        if let badge {
                            Text(badge).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == mode ? [.isSelected] : [])
    }

    private func save() {
        guard !session.isUIFixture else {
            finish()
            return
        }
        saving = true
        failure = nil
        let controller = session.controlPlane
        let choice = choice
        let allowsAppleServices = allowsAppleServices
        Task { @MainActor in
            defer { saving = false }
            do {
                // The group goes in first, so Ask Me doesn't ask about Apple's services.
                if allowsAppleServices {
                    let groups = try await controller.policyDefinitions().groups
                    if !groups.contains(where: { $0.name == BuiltInRuleGroups.macOSServicesName }) {
                        try await controller.addMacOSServicesGroup()
                    }
                }
                if choice != .silentAllow { _ = try await controller.setEffectiveMode(choice) }
                if keepsHistory {
                    try await controller.configureHistory(
                        enabled: true, retentionDays: Self.historyDays, maximumFlows: 50_000
                    )
                }
            } catch {
                failure = "Rift couldn’t save your choice. Try again."
                return
            }
            finish()
            do {
                try LoginItem.set(opensAtLogin)
                controller.actionResults.post("You’re all set. \(choice.summary)")
            } catch {
                controller.actionResults.post(
                    "macOS couldn’t change whether Rift opens at login. Check Login Items in System Settings.",
                    tone: .pending
                )
            }
        }
    }
}
