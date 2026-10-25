public struct InterfaceRouteSnapshot: Sendable, Hashable, Codable {
    public let generation: UInt64
    public let directlyConnectedRoutes: [IPInterval]
    public let directedBroadcasts: Set<IPAddress>

    public init(
        generation: UInt64,
        directlyConnectedRoutes: [IPInterval],
        directedBroadcasts: Set<IPAddress>
    ) {
        self.generation = generation
        self.directlyConnectedRoutes = Array(Set(directlyConnectedRoutes)).sorted()
        self.directedBroadcasts = directedBroadcasts
    }
}

public struct InterfaceAddressRecord: Sendable, Hashable {
    public let address: IPAddress
    public let netmask: IPAddress
    public let broadcast: IPAddress?
    public let pointToPointPeer: IPAddress?
    public let isUp: Bool
    public let isRunning: Bool
    public let isLoopback: Bool

    public init(
        address: IPAddress,
        netmask: IPAddress,
        broadcast: IPAddress? = nil,
        pointToPointPeer: IPAddress? = nil,
        isUp: Bool,
        isRunning: Bool,
        isLoopback: Bool
    ) {
        self.address = address
        self.netmask = netmask
        self.broadcast = broadcast
        self.pointToPointPeer = pointToPointPeer
        self.isUp = isUp
        self.isRunning = isRunning
        self.isLoopback = isLoopback
    }
}

public enum InterfaceRouteSnapshotBuilder {
    public static func build(
        generation: UInt64,
        records: [InterfaceAddressRecord]
    ) -> InterfaceRouteSnapshot {
        var routes: Set<IPInterval> = []
        var broadcasts: Set<IPAddress> = []
        for record in records where record.isUp && record.isRunning && !record.isLoopback {
            guard record.address.family == record.netmask.family,
                  !record.address.bytes.allSatisfy({ $0 == 0 }),
                  let prefixLength = contiguousPrefixLength(record.netmask),
                  prefixLength > 0,
                  let route = try? IPInterval(cidr: record.address, prefixLength: prefixLength)
            else { continue }
            routes.insert(route)

            if prefixLength <= 30,
               let broadcast = record.broadcast,
               broadcast.family == .ipv4,
               route.upperBound == broadcast {
                broadcasts.insert(broadcast)
            }
            if let peer = record.pointToPointPeer,
               peer.family == record.address.family,
               !peer.bytes.allSatisfy({ $0 == 0 }) {
                routes.insert(IPInterval(exact: peer))
            }
        }
        return InterfaceRouteSnapshot(
            generation: generation,
            directlyConnectedRoutes: Array(routes),
            directedBroadcasts: broadcasts
        )
    }

    private static func contiguousPrefixLength(_ netmask: IPAddress) -> Int? {
        var length = 0
        var foundZero = false
        for byte in netmask.bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                if byte & (1 << bit) != 0 {
                    guard !foundZero else { return nil }
                    length += 1
                } else {
                    foundZero = true
                }
            }
        }
        return length
    }
}

public enum EndpointClassifier {
    public static func classify(
        address: IPAddress,
        observedHostname: DomainName?,
        snapshot: InterfaceRouteSnapshot?
    ) -> Set<EndpointClass> {
        var result: Set<EndpointClass> = []
        if isLoopback(address) { result.insert(.loopback) }
        if isLinkLocal(address) { result.insert(.linkLocal) }
        if isMulticast(address) { result.insert(.multicast) }
        if isLimitedBroadcast(address) || snapshot?.directedBroadcasts.contains(address) == true {
            result.insert(.broadcast)
        }
        if isBonjourAddress(address) || observedHostname?.ascii.hasSuffix(".local") == true ||
            observedHostname?.ascii == "local" {
            result.insert(.bonjour)
        }
        if snapshot?.directlyConnectedRoutes.contains(where: { $0.contains(address) }) == true {
            result.insert(.localNetwork)
        }
        return result
    }

    private static func isLoopback(_ address: IPAddress) -> Bool {
        switch address.family {
        case .ipv4: address.bytes[0] == 127
        case .ipv6: address.bytes.dropLast().allSatisfy { $0 == 0 } && address.bytes.last == 1
        }
    }

    private static func isLinkLocal(_ address: IPAddress) -> Bool {
        switch address.family {
        case .ipv4:
            address.bytes[0] == 169 && address.bytes[1] == 254
        case .ipv6:
            address.bytes[0] == 0xFE && (address.bytes[1] & 0xC0) == 0x80
        }
    }

    private static func isMulticast(_ address: IPAddress) -> Bool {
        switch address.family {
        case .ipv4: (address.bytes[0] & 0xF0) == 0xE0
        case .ipv6: address.bytes[0] == 0xFF
        }
    }

    private static func isLimitedBroadcast(_ address: IPAddress) -> Bool {
        address.family == .ipv4 && address.bytes.allSatisfy { $0 == 0xFF }
    }

    private static func isBonjourAddress(_ address: IPAddress) -> Bool {
        switch address.family {
        case .ipv4:
            address.bytes == [224, 0, 0, 251]
        case .ipv6:
            address.bytes == [0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFB]
        }
    }
}
