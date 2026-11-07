import RiftControl
import RiftCore
import SwiftUI

/// The rule fields most people never need, kept out of the way.
struct RuleEditorAdvancedSection: View {
    @Binding var isExpanded: Bool
    @Binding var owner: OwnerCondition
    @Binding var transport: ManualRuleEditorView.ProtocolChoice
    @Binding var direction: DirectionCondition
    @Binding var portText: String
    @Binding var profileID: UUID?
    @Binding var localGroupID: UUID?
    @Binding var temporary: Bool
    @Binding var expiry: Date
    @Binding var isEnabled: Bool
    @Binding var isReviewed: Bool
    @Binding var note: String
    let permitsSystemOwner: Bool
    let profiles: [PolicyProfile]
    let groups: [LocalRuleGroup]

    var body: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $isExpanded) {
                Picker("Owner", selection: $owner) {
                    Text("Your account").tag(OwnerCondition.authorizedUser)
                    Text("System process").tag(OwnerCondition.system)
                        .disabled(!permitsSystemOwner)
                }
                if owner == .system {
                    Text("System rules apply no matter who is logged in.")
                        .foregroundStyle(.orange)
                }
                Picker("Protocol", selection: $transport) {
                    ForEach(ManualRuleEditorView.ProtocolChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Direction", selection: $direction) {
                    Text("Outgoing").tag(DirectionCondition.outgoing)
                    Text("Incoming").tag(DirectionCondition.incoming)
                    Text("Both").tag(DirectionCondition.bidirectional)
                }
                TextField("Port or range", text: $portText, prompt: Text("Any"))
                Picker("Profile", selection: $profileID) {
                    Text("All profiles").tag(UUID?.none)
                    ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Group", selection: $localGroupID) {
                    Text("No group").tag(UUID?.none)
                    ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Temporary", isOn: $temporary)
                if temporary { DatePicker("Expires", selection: $expiry, in: Date()...) }
                Toggle("On", isOn: $isEnabled)
                Toggle("Reviewed", isOn: $isReviewed)
                TextField("Note", text: $note, axis: .vertical).lineLimit(2...4)
            }
        }
    }
}
