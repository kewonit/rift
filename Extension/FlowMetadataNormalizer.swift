import AbyssCore
import Darwin
import Foundation
@preconcurrency import NetworkExtension

struct CapturedFlowMetadata: Sendable {
    let descriptor: FlowDescriptor
    let sourceAppAuditToken: Data?
    let sourceProcessAuditToken: Data?
}

enum FlowMetadataNormalizer {
    static func capture(
        _ flow: NEFilterFlow,
        interfaceSnapshot: InterfaceRouteSnapshot,
        now: Date = Date()
    ) -> CapturedFlowMetadata {
        let socket = flow as? NEFilterSocketFlow
        let hostname = socket?.remoteHostname.flatMap { try? DomainName($0) }
        let localParts = socket.flatMap(AbyssCopyLocalEndpointParts)
        let remoteParts = socket.flatMap(AbyssCopyRemoteEndpointParts)
        let local = endpoint(from: localParts, hostname: nil, snapshot: interfaceSnapshot)
        let remote = endpoint(from: remoteParts, hostname: hostname, snapshot: interfaceSnapshot)
        let direction: TrafficDirection = flow.direction == .inbound ? .incoming : .outgoing
        let appToken = flow.sourceAppAuditToken as Data?
        let processToken = flow.sourceProcessAuditToken as Data?
        let owner = flowOwner(from: appToken ?? processToken)
        var confidence: MetadataConfidence = []
        if local != nil || remote != nil { confidence.insert(.endpoint) }
        if hostname != nil { confidence.insert(.observedHostname) }
        if owner != .unknown { confidence.insert(.owner) }
        return CapturedFlowMetadata(
            descriptor: FlowDescriptor(
                flowID: flow.identifier as UUID,
                observedAt: now,
                sourceAppIdentity: nil,
                sourceProcessIdentity: nil,
                owner: owner,
                direction: direction,
                transportProtocol: transportProtocol(socket),
                localEndpoint: local,
                remoteEndpoint: remote,
                observedHostname: hostname,
                metadataConfidence: confidence
            ),
            sourceAppAuditToken: appToken,
            sourceProcessAuditToken: processToken
        )
    }

    private static func endpoint(
        from parts: [String: Any]?,
        hostname: DomainName?,
        snapshot: InterfaceRouteSnapshot
    ) -> Endpoint? {
        guard let host = parts?["host"] as? String,
              let address = try? IPAddress(host) else { return nil }
        let port: UInt16?
        if let number = parts?["port"] as? NSNumber {
            port = number.uint16Value == 0 ? nil : number.uint16Value
        } else if let string = parts?["port"] as? String, let value = UInt16(string), value != 0 {
            port = value
        } else {
            port = nil
        }
        return Endpoint(
            address: address,
            port: port,
            hostname: hostname,
            hostnameCoverage: hostname == nil ? .absent : .observed,
            classes: EndpointClassifier.classify(
                address: address,
                observedHostname: hostname,
                snapshot: snapshot
            ),
            interfaceSnapshotGeneration: snapshot.generation
        )
    }

    private static func transportProtocol(_ socket: NEFilterSocketFlow?) -> TransportProtocol {
        guard let socket else { return .unsupported(number: 0) }
        switch socket.socketProtocol {
        case IPPROTO_TCP: return .tcp
        case IPPROTO_UDP: return .udp
        default: return .unsupported(number: UInt8(clamping: socket.socketProtocol))
        }
    }

    private static func flowOwner(from token: Data?) -> FlowOwner {
        let uid = AbyssAuditTokenEUID(token)
        if uid == UInt32.max { return .unknown }
        return uid == 0 ? .system : .user(uid: uid)
    }
}
