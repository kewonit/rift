import Foundation
import RiftCore

/// Where a connection's peer is, for grouping the list by country: where an
/// outgoing connection went, or where an incoming one came from.
struct MonitorCountryGroup: Hashable {
    let key: String
    let title: String

    init(_ flow: FlowDescriptor, context: MonitorSearchContext) {
        guard let peer = flow.remoteEndpoint else {
            self.init(key: "unknown", title: "Unknown location")
            return
        }
        if peer.classes.contains(.loopback) {
            self.init(key: "this-mac", title: "This Mac")
        } else if !peer.classes.isEmpty {
            self.init(key: "local-network", title: "Local network")
        } else if let code = context.countryCode?(peer.address) {
            self.init(key: "country:" + code, title: context.countryName?(code) ?? code)
        } else {
            self.init(key: "unknown", title: "Unknown location")
        }
    }

    private init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}
