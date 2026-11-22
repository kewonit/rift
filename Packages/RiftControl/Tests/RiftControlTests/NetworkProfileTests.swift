import Foundation
import Testing
@testable import RiftControl

@Test func networksAreRecognizedByWiFiNameOrRouter() {
    let named = NetworkIdentity(kind: .wifi, wifiName: "Home", router: "192.168.1.1")
    #expect(named.key == "wifi-name:Home")
    #expect(named.displayName == "Home")
    let unnamed = NetworkIdentity(kind: .wifi, wifiName: nil, router: "192.168.1.1")
    #expect(unnamed.key == "wifi-router:192.168.1.1")
    #expect(unnamed.displayName == "Wi-Fi with router 192.168.1.1")
    let wired = NetworkIdentity(kind: .wired, wifiName: "Ignored", router: "10.0.0.1")
    #expect(wired.key == "wired-router:10.0.0.1")
    #expect(NetworkIdentity(kind: .other, wifiName: nil, router: nil).key == nil)
    // Control characters in a network name can't spoof the UI.
    #expect(NetworkIdentity(kind: .wifi, wifiName: "Ho\u{202E}me", router: nil).wifiName?.contains("\u{202E}") == false)
}

@Test func theProfileFollowsTheNetworksChoice() {
    let work = UUID()
    let office = NetworkIdentity(kind: .wifi, wifiName: "Office", router: nil)
    let cafe = NetworkIdentity(kind: .wifi, wifiName: "Cafe", router: nil)
    let remembered = [
        "wifi-name:Office": RememberedNetwork(key: "wifi-name:Office", name: "Office", choice: .profile(work), lastSeenAt: Date()),
    ]
    #expect(NetworkProfileDecision.target(on: office, remembered: remembered, otherNetworks: .leaveAsIs, profiles: [work])
        == .some(work))
    // A new network uses the choice for new networks.
    #expect(NetworkProfileDecision.target(on: cafe, remembered: remembered, otherNetworks: .noProfile, profiles: [work])
        == .some(nil))
    #expect(NetworkProfileDecision.target(on: cafe, remembered: remembered, otherNetworks: .leaveAsIs, profiles: [work])
        == nil)
    // A removed profile leaves things alone.
    #expect(NetworkProfileDecision.target(on: office, remembered: remembered, otherNetworks: .leaveAsIs, profiles: [])
        == nil)
}

@Test func networkChoicesSurviveStorage() throws {
    let choice = NetworkProfileChoice.profile(UUID())
    #expect(try JSONDecoder().decode(NetworkProfileChoice.self, from: JSONEncoder().encode(choice)) == choice)
}

@Test func networksSavedBeforeLessStrictApprovalStillRead() throws {
    let old = Data(#"{"key":"wired:192.0.2.1","name":"Ethernet","choice":{"leaveAsIs":{}},"lastSeenAt":0}"#.utf8)
    let network = try JSONDecoder().decode(RememberedNetwork.self, from: old)
    #expect(network.allowsLessStrictSwitch == nil)
    // Nothing new is written until the person allows it, so archives keep their shape.
    let encoded = String(decoding: try JSONEncoder().encode(network), as: UTF8.self)
    #expect(!encoded.contains("allowsLessStrictSwitch"))
}
