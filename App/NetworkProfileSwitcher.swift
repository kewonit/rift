import CoreLocation
import CoreWLAN
import Foundation
import Network
import Observation
import RiftControl
import RiftIPC
import UserNotifications

/// Switches profiles when the Mac joins a network the person chose a profile
/// for. Off until turned on in Settings › Networks.
///
/// A switch that would weaken protection isn't made on its own, because
/// anyone can name a Wi-Fi network after yours. Rift says so in a
/// notification instead, and the switch can be made from the menu bar.
@MainActor
@Observable
final class NetworkProfileSwitcher {
    static let shared = NetworkProfileSwitcher()

    private enum Key {
        static let enabled = "networkProfilesEnabled"
        static let wifiNames = "networkProfilesUseWiFiNames"
        static let remembered = "networkProfilesRemembered"
        static let otherNetworks = "networkProfilesOtherNetworks"
        static let notify = "networkProfilesNotify"
    }

    var enabled: Bool {
        didSet { save(); if enabled { refresh() } }
    }
    var notifies: Bool { didSet { save() } }
    /// Reading Wi-Fi names needs Location Services permission on macOS.
    var usesWiFiNames: Bool {
        didSet {
            save()
            if usesWiFiNames { location.request() }
            refresh()
        }
    }
    var otherNetworks: NetworkProfileChoice { didSet { save() } }
    private(set) var remembered: [String: RememberedNetwork]
    private(set) var current: NetworkIdentity?
    private(set) var lastMessage: String?
    var locationStatus: CLAuthorizationStatus { location.status }

    @ObservationIgnored private weak var controlPlane: ControlPlaneController?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: NWPath?
    @ObservationIgnored private let location = LocationPermission()
    @ObservationIgnored private var notifiedNew: Set<String> = []

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Key.enabled)
        notifies = defaults.object(forKey: Key.notify) as? Bool ?? true
        usesWiFiNames = defaults.bool(forKey: Key.wifiNames)
        otherNetworks = defaults.data(forKey: Key.otherNetworks)
            .flatMap { try? JSONDecoder().decode(NetworkProfileChoice.self, from: $0) } ?? .leaveAsIs
        let saved = defaults.data(forKey: Key.remembered)
            .flatMap { try? JSONDecoder().decode([RememberedNetwork].self, from: $0) } ?? []
        remembered = Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        location.changed = { [weak self] in self?.refresh() }
    }

    func start(controlPlane: ControlPlaneController) {
        self.controlPlane = controlPlane
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.update(path) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func setChoice(_ choice: NetworkProfileChoice, for key: String) {
        guard var network = remembered[key] else { return }
        network.choice = choice
        remembered[key] = network
        save()
        if key == current?.key { Task { await apply(force: true) } }
    }

    func forget(_ key: String) {
        remembered.removeValue(forKey: key)
        save()
    }

    /// Settings › Networks, as a configuration archive keeps it.
    var archived: ArchivedNetworkProfiles {
        ArchivedNetworkProfiles(
            enabled: enabled, notifies: notifies, usesWiFiNames: usesWiFiNames,
            otherNetworks: otherNetworks, remembered: Array(remembered.values)
        )
    }

    /// Takes Settings › Networks from a restored archive.
    func restore(_ archived: ArchivedNetworkProfiles) {
        remembered = Dictionary(archived.remembered.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        notifiedNew = Set(remembered.keys)
        otherNetworks = archived.otherNetworks
        notifies = archived.notifies
        usesWiFiNames = archived.usesWiFiNames
        enabled = archived.enabled
        save()
        refresh()
    }

    private func refresh() {
        if let lastPath { update(lastPath, force: true) }
    }

    private func update(_ path: NWPath, force: Bool = false) {
        lastPath = path
        let identity = Self.identity(for: path, readWiFiName: usesWiFiNames && location.isAuthorized)
        guard force || identity != current else { return }
        current = identity
        // Nothing is remembered while switching is off.
        guard enabled else { return }
        if let key = identity?.key, let identity {
            var network = remembered[key]
                ?? RememberedNetwork(key: key, name: identity.displayName, choice: otherNetworks, lastSeenAt: Date())
            let isNew = remembered[key] == nil
            network.lastSeenAt = Date()
            remembered[key] = network
            save()
            if isNew, notifies, notifiedNew.insert(key).inserted {
                notify("New network: \(identity.displayName)", "Choose a profile for it in Settings › Networks.")
            }
        }
        Task { await apply(force: force) }
    }

    private func apply(force: Bool) async {
        guard enabled, let controlPlane, let network = current,
              let definitions = try? await controlPlane.policyDefinitions() else { return }
        let profiles = Dictionary(uniqueKeysWithValues: definitions.profiles.map { ($0.id, $0.name) })
        guard let target = NetworkProfileDecision.target(
            on: network, remembered: remembered, otherNetworks: otherNetworks, profiles: Set(profiles.keys)
        ), target != definitions.active else { return }
        let name = target.flatMap { profiles[$0] } ?? "No profile"
        do {
            _ = try await controlPlane.activateProfile(target, unattended: true)
            lastMessage = "Switched to \(name) for \(network.displayName)."
            if notifies { notify("Switched to \(name)", "For the network \(network.displayName).") }
        } catch CLIRelayRefusal.profileSwitchNeedsConfirmation {
            lastMessage = "\(name) is less strict, so Rift didn’t switch to it on its own."
            if notifies {
                notify(
                    "Rift didn’t switch to \(name)",
                    "\(name) is less strict than the current profile. To use it on \(network.displayName), choose it from the menu bar."
                )
            }
        } catch {
            lastMessage = "Rift couldn’t switch to \(name)."
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "rift-network-\(UUID().uuidString)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private static func identity(for path: NWPath, readWiFiName: Bool) -> NetworkIdentity? {
        guard path.status == .satisfied else { return nil }
        let kind: NetworkIdentity.Kind = path.usesInterfaceType(.wifi) ? .wifi
            : path.usesInterfaceType(.wiredEthernet) ? .wired : .other
        let router = path.gateways.lazy.compactMap { endpoint -> String? in
            guard case .hostPort(let host, _) = endpoint else { return nil }
            switch host {
            case .ipv4(let address): return "\(address)"
            case .ipv6(let address): return "\(address)"
            default: return nil
            }
        }.first
        let wifiName = kind == .wifi && readWiFiName ? CWWiFiClient.shared().interface()?.ssid() : nil
        return NetworkIdentity(kind: kind, wifiName: wifiName, router: router)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(notifies, forKey: Key.notify)
        defaults.set(usesWiFiNames, forKey: Key.wifiNames)
        defaults.set(try? JSONEncoder().encode(otherNetworks), forKey: Key.otherNetworks)
        defaults.set(try? JSONEncoder().encode(Array(remembered.values)), forKey: Key.remembered)
    }
}

/// Asks for the Location Services permission macOS requires before an app
/// can read Wi-Fi names. Rift never asks for the Mac's location.
@MainActor
private final class LocationPermission: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var changed: (@MainActor () -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var isAuthorized: Bool { ![.notDetermined, .denied, .restricted].contains(status) }

    func request() {
        guard status == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        changed?()
    }
}
