import RiftCore
import Darwin
import Foundation
import Network

final class InterfaceRouteSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.rift.filter.interface-routes", qos: .utility)
    private var current: InterfaceRouteSnapshot

    init() {
        current = InterfaceRouteSnapshotBuilder.build(
            generation: 1,
            records: InterfaceAddressReader.records()
        )
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.rebuild()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func load() -> InterfaceRouteSnapshot {
        lock.withLock { current }
    }

    private func rebuild() {
        let records = InterfaceAddressReader.records()
        lock.withLock {
            let nextGeneration = current.generation == .max ? .max : current.generation + 1
            let candidate = InterfaceRouteSnapshotBuilder.build(
                generation: nextGeneration,
                records: records
            )
            guard candidate.directlyConnectedRoutes != current.directlyConnectedRoutes ||
                    candidate.directedBroadcasts != current.directedBroadcasts
            else { return }
            current = candidate
        }
    }
}

private enum InterfaceAddressReader {
    static func records() -> [InterfaceAddressRecord] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var result: [InterfaceAddressRecord] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let value = pointer.pointee
            cursor = value.ifa_next
            guard let interfaceAddress = address(value.ifa_addr),
                  let netmask = address(value.ifa_netmask)
            else { continue }

            let flags = value.ifa_flags
            let sharedDestination = address(value.ifa_dstaddr)
            result.append(InterfaceAddressRecord(
                address: interfaceAddress,
                netmask: netmask,
                broadcast: flags & UInt32(IFF_BROADCAST) == 0 ? nil : sharedDestination,
                pointToPointPeer: flags & UInt32(IFF_POINTOPOINT) == 0 ? nil : sharedDestination,
                isUp: flags & UInt32(IFF_UP) != 0,
                isRunning: flags & UInt32(IFF_RUNNING) != 0,
                isLoopback: flags & UInt32(IFF_LOOPBACK) != 0
            ))
        }
        return result
    }

    private static func address(_ pointer: UnsafePointer<sockaddr>?) -> RiftCore.IPAddress? {
        guard let pointer,
              pointer.pointee.sa_family == sa_family_t(AF_INET) ||
                pointer.pointee.sa_family == sa_family_t(AF_INET6)
        else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = buffer.withUnsafeMutableBufferPointer { storage in
            getnameinfo(
                pointer,
                socklen_t(pointer.pointee.sa_len),
                storage.baseAddress,
                socklen_t(storage.count),
                nil,
                0,
                NI_NUMERICHOST
            )
        }
        guard status == 0 else { return nil }
        let text = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let numeric = text.split(separator: "%", maxSplits: 1)[0]
        return try? RiftCore.IPAddress(String(numeric))
    }
}
