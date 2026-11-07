import RiftControl
import RiftCore
import SwiftUI

/// A rule someone is about to make from a connection.
struct MonitorRuleRequest: Identifiable {
    let id = UUID()
    let action: FilterAction
    let node: MonitorHierarchyNode
    let row: MonitorEventRow
    let options: [MonitorRuleBreadth]
    let application: String

    var host: String { DisplaySanitizer.plainText(MonitorQuery.hostnameLabel(row)) }
    var port: UInt16? { row.event.flow.destinationEndpoint?.port }
    var verb: String { action == .deny ? "Block" : "Allow" }
}

/// Shows exactly what a rule will cover before it's made.
struct RuleScopeChooser: View {
    let request: MonitorRuleRequest
    let confirm: (MonitorRuleBreadth, MonitorRuleDuration) -> Void
    let cancel: () -> Void
    @State private var breadth: MonitorRuleBreadth
    @State private var duration: MonitorRuleDuration = .always

    init(
        request: MonitorRuleRequest,
        confirm: @escaping (MonitorRuleBreadth, MonitorRuleDuration) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.request = request
        self.confirm = confirm
        self.cancel = cancel
        _breadth = State(initialValue: request.options.first ?? .allDestinations)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.m) {
            Text("\(request.verb) \(request.application)")
                .font(.title3.weight(.semibold))
            if request.options.count > 1 {
                Picker("Applies to", selection: $breadth) {
                    ForEach(request.options) { option in
                        Text(MonitorRuleScope.title(option, host: request.host, port: request.port))
                            .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Picker("For", selection: $duration) {
                ForEach(MonitorRuleDuration.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: RiftDesign.Spacing.xxs) {
                Text(summary)
                if let limitation = MonitorRuleScope.limitation(breadth, row: request.row) {
                    Text(limitation).font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(request.verb) { confirm(breadth, duration) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(RiftDesign.Spacing.xl)
        .frame(width: 440)
    }

    private var summary: String {
        RulePlainLanguage.change(
            action: request.action,
            application: request.application,
            destination: MonitorRuleScope.phrase(breadth, host: request.host),
            port: breadth == .exactConnection ? request.port : nil,
            incoming: request.row.event.flow.direction == .incoming,
            forOneHour: duration == .oneHour,
            isPreview: true
        )
    }
}
