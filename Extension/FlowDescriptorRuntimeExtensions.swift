import RiftCore
import RiftIPC
import Foundation

extension CapturedFlowMetadata {
    /// The process ID and path of what opened the connection, and of the app
    /// it acts for when that's another process. Read from the audit tokens
    /// only when an alert or a recorded decision is going to show them.
    func processDetails() -> FlowProcessDetails? {
        func observed(_ token: Data?) -> ObservedProcess? {
            guard let token else { return nil }
            return ObservedProcess(
                processID: RiftAuditTokenPID(token),
                executablePath: RiftCopyAuditTokenExecutablePath(token)
            )
        }
        let process = observed(sourceProcessAuditToken)
        let app = sourceAppAuditToken == sourceProcessAuditToken
            ? nil : observed(sourceAppAuditToken)
        return FlowProcessDetails(process: process ?? app, app: process == nil ? nil : app)
    }

    func withIdentities(_ resolved: ResolvedIdentityPair) -> CapturedFlowMetadata {
        CapturedFlowMetadata(
            descriptor: descriptor.withIdentities(resolved),
            sourceAppAuditToken: sourceAppAuditToken,
            sourceProcessAuditToken: sourceProcessAuditToken
        )
    }
}

extension FlowDescriptor {
    func withIdentities(_ resolved: ResolvedIdentityPair) -> FlowDescriptor {
        var confidence = metadataConfidence
        if resolved.app != nil { confidence.insert(.appIdentity) }
        if resolved.process != nil { confidence.insert(.processIdentity) }
        return copy(
            appIdentity: resolved.app,
            processIdentity: resolved.process,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint,
            hostname: observedHostname,
            confidence: confidence
        )
    }

    func redactedForPrivacy() -> FlowDescriptor {
        copy(
            appIdentity: nil,
            processIdentity: nil,
            localEndpoint: nil,
            remoteEndpoint: nil,
            hostname: nil,
            confidence: []
        )
    }

    private func copy(
        appIdentity: ProcessIdentity?,
        processIdentity: ProcessIdentity?,
        localEndpoint: Endpoint?,
        remoteEndpoint: Endpoint?,
        hostname: DomainName?,
        confidence: MetadataConfidence
    ) -> FlowDescriptor {
        FlowDescriptor(
            flowID: flowID,
            observedAt: observedAt,
            sourceAppIdentity: appIdentity,
            sourceProcessIdentity: processIdentity,
            owner: owner,
            direction: direction,
            transportProtocol: transportProtocol,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint,
            observedHostname: hostname,
            metadataConfidence: confidence
        )
    }
}
