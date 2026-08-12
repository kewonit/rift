import AbyssCore
import Foundation

public enum IPCMessageKind: String, Sendable, Codable {
    case handshake
    case claimController
    case beginConfigurationReset
    case health
    case beginSnapshot
    case appendSnapshotChunk
    case finishSnapshot
    case abortSnapshot
    case drainPrompts
    case answerPrompt
    case drainEvents
    case drainNotifications
    case prepareUninstall
    case cliRequest
}

public enum IPCReplyStatus: Int, Sendable, Codable {
    case success
    case rejected
    case incompatible
    case busy
    case invalidRequest
    case internalFailure
}

@objc(ABSecureIPCEnvelope)
public final class SecureIPCEnvelope: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let requestID: UUID
    public let kind: String
    public let controllerLeaseID: UUID?
    public let payload: Data

    public init(
        protocolVersion: ProtocolVersion = .current,
        requestID: UUID = UUID(),
        kind: IPCMessageKind,
        controllerLeaseID: UUID? = nil,
        payload: Data = Data()
    ) {
        self.protocolMajor = protocolVersion.major
        self.protocolMinor = protocolVersion.minor
        self.requestID = requestID
        self.kind = kind.rawValue
        self.controllerLeaseID = controllerLeaseID
        self.payload = payload
    }

    public required init?(coder: NSCoder) {
        let major = coder.decodeInteger(forKey: "protocolMajor")
        let minor = coder.decodeInteger(forKey: "protocolMinor")
        guard major >= 0, major <= UInt16.max, minor >= 0, minor <= UInt16.max,
              let requestID = coder.decodeObject(of: NSUUID.self, forKey: "requestID") as UUID?,
              let kind = coder.decodeObject(of: NSString.self, forKey: "kind") as String?,
              let payload = coder.decodeObject(of: NSData.self, forKey: "payload") as Data?,
              payload.count <= IPCProtocolLimits.maximumEnvelopePayloadBytes else { return nil }
        let lease = coder.decodeObject(of: NSUUID.self, forKey: "controllerLeaseID") as UUID?
        self.protocolMajor = UInt16(major)
        self.protocolMinor = UInt16(minor)
        self.requestID = requestID
        self.kind = kind
        self.controllerLeaseID = lease
        self.payload = payload
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(protocolMajor), forKey: "protocolMajor")
        coder.encode(Int(protocolMinor), forKey: "protocolMinor")
        coder.encode(requestID as NSUUID, forKey: "requestID")
        coder.encode(kind as NSString, forKey: "kind")
        coder.encode(controllerLeaseID as NSUUID?, forKey: "controllerLeaseID")
        coder.encode(payload as NSData, forKey: "payload")
    }

    public var protocolVersion: ProtocolVersion {
        ProtocolVersion(major: protocolMajor, minor: protocolMinor)
    }

    public var messageKind: IPCMessageKind? { IPCMessageKind(rawValue: kind) }
}

@objc(ABSecureIPCReply)
public final class SecureIPCReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let requestID: UUID
    public let statusCode: Int
    public let payload: Data
    public let redactedErrorCode: String?

    public init(
        requestID: UUID,
        status: IPCReplyStatus,
        payload: Data = Data(),
        redactedErrorCode: String? = nil
    ) {
        self.requestID = requestID
        self.statusCode = status.rawValue
        self.payload = payload
        self.redactedErrorCode = redactedErrorCode.map { String($0.prefix(128)) }
    }

    public required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSUUID.self, forKey: "requestID") as UUID?,
              let payload = coder.decodeObject(of: NSData.self, forKey: "payload") as Data?,
              payload.count <= IPCProtocolLimits.maximumReplyPayloadBytes else { return nil }
        let error = coder.decodeObject(of: NSString.self, forKey: "redactedErrorCode") as String?
        guard error?.count ?? 0 <= 128 else { return nil }
        self.requestID = requestID
        self.statusCode = coder.decodeInteger(forKey: "statusCode")
        self.payload = payload
        self.redactedErrorCode = error
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSUUID, forKey: "requestID")
        coder.encode(statusCode, forKey: "statusCode")
        coder.encode(payload as NSData, forKey: "payload")
        coder.encode(redactedErrorCode as NSString?, forKey: "redactedErrorCode")
    }

    public var status: IPCReplyStatus? { IPCReplyStatus(rawValue: statusCode) }
}

@objc public protocol AbyssFilterControlXPC {
    func handshake(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func claimController(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func beginConfigurationReset(
        _ request: SecureIPCEnvelope,
        withReply reply: @escaping (SecureIPCReply) -> Void
    )
    func health(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func beginSnapshot(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func appendSnapshotChunk(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func finishSnapshot(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func abortSnapshot(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func drainPrompts(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func answerPrompt(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func drainEvents(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func drainNotifications(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func prepareUninstall(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
    func cliRequest(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void)
}

@objc public protocol AbyssAppRelayXPC {
    func performCLIRequest(
        _ request: SecureIPCEnvelope,
        withReply reply: @escaping (SecureIPCReply) -> Void
    )
    func runtimeDataAvailable(withReply reply: @escaping () -> Void)
}

public enum SecureIPCCodec {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try CanonicalPolicyJSON.encoder().encode(value)
    }

    public static func decode<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
        let value = try CanonicalPolicyJSON.decoder().decode(type, from: data)
        let canonical = try CanonicalPolicyJSON.encoder().encode(value)
        let inputObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let canonicalObject = try JSONSerialization.jsonObject(
            with: canonical,
            options: [.fragmentsAllowed]
        )
        guard containsOnlyKnownShape(inputObject, canonical: canonicalObject) else {
            throw SecureIPCCodecError.unknownField
        }
        return value
    }

    private static func containsOnlyKnownShape(_ input: Any, canonical: Any) -> Bool {
        if let input = input as? [String: Any] {
            guard let canonical = canonical as? [String: Any] else { return false }
            return input.allSatisfy { key, value in
                canonical[key].map { containsOnlyKnownShape(value, canonical: $0) } ?? false
            }
        }
        if let input = input as? [Any] {
            guard let canonical = canonical as? [Any], input.count == canonical.count else {
                return false
            }
            return zip(input, canonical).allSatisfy {
                containsOnlyKnownShape($0.0, canonical: $0.1)
            }
        }
        return !(canonical is [String: Any]) && !(canonical is [Any])
    }
}

public enum SecureIPCCodecError: Error, Sendable, Equatable {
    case unknownField
}
