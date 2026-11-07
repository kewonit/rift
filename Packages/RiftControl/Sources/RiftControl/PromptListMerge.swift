import Foundation
import RiftIPC

/// Keeps the waiting list in a stable order. An updated prompt replaces the
/// old one where it stands, so the alert someone is reading can't be swapped
/// for a different connection underneath them.
public enum PromptListMerge {
    public static func merged(
        existing: [PromptRequest],
        incoming: [PromptRequest],
        now: Date
    ) -> [PromptRequest] {
        var result = existing
        for prompt in incoming where prompt.deadline > now {
            let matches = result.indices.filter { represent(result[$0], prompt) }
            if let first = matches.first {
                result[first] = prompt
                for index in matches.dropFirst().reversed() { result.remove(at: index) }
            } else {
                result.append(prompt)
            }
        }
        return result.filter { $0.deadline > now }
    }

    private static func represent(_ lhs: PromptRequest, _ rhs: PromptRequest) -> Bool {
        lhs.nonce == rhs.nonce
            || (lhs.providerEpoch == rhs.providerEpoch && lhs.flowID == rhs.flowID)
    }
}
