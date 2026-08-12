import CryptoKit
import Foundation

public enum DiagnosticsPseudonymizerError: Error, Sendable, Equatable {
    case insufficientKeyMaterial
}

public struct DiagnosticsPseudonymizer: Sendable {
    private let key: SymmetricKey

    public init() {
        key = SymmetricKey(size: .bits256)
    }

    public init(keyMaterial: Data) throws {
        guard keyMaterial.count >= 32 else {
            throw DiagnosticsPseudonymizerError.insufficientKeyMaterial
        }
        key = SymmetricKey(data: keyMaterial)
    }

    public func token(for value: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return digest.prefix(9).map { String(format: "%02x", $0) }.joined()
    }
}
