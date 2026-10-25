import Dispatch
import Foundation

public final class BoundedIdentityWorkerPool {
    public static let maximumConcurrentWorkItems = 2

    private let lanes: [DispatchQueue]
    private let assignmentLock = NSLock()
    private var nextLane = 0

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        lanes = (0..<Self.maximumConcurrentWorkItems).map { lane in
            DispatchQueue(label: "\(label).\(lane)", qos: qos)
        }
    }

    public func submit(_ work: @escaping @Sendable () -> Void) {
        assignmentLock.lock()
        let lane = lanes[nextLane]
        nextLane = (nextLane + 1) % lanes.count
        assignmentLock.unlock()
        lane.async(execute: work)
    }
}
