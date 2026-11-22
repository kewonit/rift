import RiftControl
import SwiftUI

/// What a lasting answer covers: the destination, the profiles and a note.
struct ConnectionAlertRuleOptions: View {
    @Binding var destinationScope: AlertDestinationChoice
    @Binding var scope: ConnectionAlertView.RuleScope
    @Binding var note: String
    var noteFocused: FocusState<Bool>.Binding
    let choices: [AlertDestinationChoice]
    let registeredDomain: String?
    let showsScope: Bool
    let scopeTitle: (ConnectionAlertView.RuleScope) -> String
    let noteValid: Bool

    var body: some View {
        Picker("Destination", selection: $destinationScope) {
            ForEach(choices) { choice in
                Text(choice == .domain ? String(localized: "\(registeredDomain ?? "") and its subdomains") : choice.displayName)
                    .tag(choice)
            }
        }
        if destinationScope == .exact {
            Text("Applies to this destination on this port, for the same protocol and direction.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if destinationScope == .anyPort {
            Text("Applies to this destination on any port, for the same protocol and direction.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if destinationScope == .domain {
            Text(registeredDomain.map {
                String(localized: "Applies to every name under \($0) on any port, for the same protocol and direction.")
            } ?? String(localized: "Applies to every name under this domain on any port, for the same protocol and direction."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if destinationScope == .any {
            Label(
                "This rule will apply to all destinations for this app with the same protocol, direction, and owner.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if showsScope {
            Picker("Apply to", selection: $scope) {
                ForEach(ConnectionAlertView.RuleScope.allCases) { Text(scopeTitle($0)).tag($0) }
            }
        }
        TextField("Note (optional)", text: $note, axis: .vertical)
            .lineLimit(2...4)
            .focused(noteFocused)
        if !noteValid {
            Text("This note is too long.").font(.caption).foregroundStyle(.red)
        }
    }
}
