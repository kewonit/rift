import AppKit
import CoreLocation
import RiftControl
import RiftCore
import SwiftUI

/// Settings › Networks: which profile to use on which network.
struct NetworkSettingsPane: View {
    let profiles: [PolicyProfile]
    @Bindable private var switcher = NetworkProfileSwitcher.shared

    var body: some View {
        Form {
            Section {
                Toggle("Switch profiles by network", isOn: $switcher.enabled)
                Toggle("Notify me when Rift switches or finds a new network", isOn: $switcher.notifies)
                    .disabled(!switcher.enabled)
                Toggle("Recognize Wi-Fi networks by name", isOn: $switcher.usesWiFiNames)
                if switcher.usesWiFiNames {
                    locationNote
                }
            } footer: {
                Text("Rift switches on its own only to a profile at least as strict as the current one. Anyone can name a Wi-Fi network after yours, so when a network calls for a less strict profile, Rift notifies you instead, and you can switch from the menu bar. While you're on a network, you can allow it there anyway.")
            }
            Section("This network") {
                if let current = switcher.current, let key = current.key {
                    picker(current.displayName, key: key, choice: switcher.remembered[key]?.choice ?? switcher.otherNetworks)
                    if let network = switcher.remembered[key], network.choice != .leaveAsIs {
                        Toggle("Switch even when it’s less strict", isOn: Binding(
                            get: { network.allowsLessStrictSwitch == true },
                            set: { switcher.setAllowsLessStrict($0, for: key) }
                        ))
                        Text("Another network can use this name or router address. Rift always tells you when it makes a less strict switch, and changing this network’s profile turns this off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not connected to a network Rift can recognize.").foregroundStyle(.secondary)
                }
                if let message = switcher.lastMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("New networks", selection: $switcher.otherNetworks) { choices }
                let others = switcher.remembered.values
                    .filter { $0.key != switcher.current?.key }
                    .sorted { $0.lastSeenAt > $1.lastSeenAt }
                ForEach(others) { network in
                    HStack {
                        picker(Self.name(of: network), key: network.key, choice: network.choice)
                        Button {
                            switcher.forget(network.key)
                        } label: {
                            Label("Forget \(DisplaySanitizer.plainText(Self.name(of: network)))", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this network")
                    }
                }
            } header: {
                Text("Networks Rift has seen")
            } footer: {
                Text("A new network starts with the choice for new networks. Rift remembers networks only on this Mac.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var locationNote: some View {
        switch switcher.locationStatus {
        case .denied, .restricted:
            HStack {
                Label("Rift can’t read Wi-Fi names because Location Services is off for Rift.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .font(.caption)
        default:
            Text("macOS lets apps read Wi-Fi names only with Location Services permission. Rift reads only the network’s name, never the Mac’s location. Without it, Rift recognizes networks by their router’s address.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func picker(_ title: String, key: String, choice: NetworkProfileChoice) -> some View {
        Picker(DisplaySanitizer.plainText(title), selection: Binding(
            get: { choice },
            set: { switcher.setChoice($0, for: key) }
        )) { choices }
    }

    @ViewBuilder
    private var choices: some View {
        Text("Leave the profile as it is").tag(NetworkProfileChoice.leaveAsIs)
        Text("No profile").tag(NetworkProfileChoice.noProfile)
        if !profiles.isEmpty { Divider() }
        ForEach(profiles) { profile in
            Text(profile.name).tag(NetworkProfileChoice.profile(profile.id))
        }
    }

    /// A remembered network's name in the current language. Its saved name
    /// stays in English, so it's worked out again from its key.
    private static func name(of network: RememberedNetwork) -> String {
        NetworkIdentity.displayName(forKey: network.key) ?? network.name
    }
}
