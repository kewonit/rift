import RiftCore
import Foundation

public enum PublicIPAddressResponseError: Error, Sendable, Equatable {
    case empty
    case tooLarge
    case invalidEncoding
    case invalidAddress
}

public enum PublicIPAddressResponse {
    public static let maximumBytes = 64

    public static func parse(_ data: Data) throws -> IPAddress {
        guard !data.isEmpty else { throw PublicIPAddressResponseError.empty }
        guard data.count <= maximumBytes else { throw PublicIPAddressResponseError.tooLarge }
        guard let value = String(data: data, encoding: .utf8) else {
            throw PublicIPAddressResponseError.invalidEncoding
        }
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw PublicIPAddressResponseError.empty }
        do {
            return try IPAddress(address)
        } catch {
            throw PublicIPAddressResponseError.invalidAddress
        }
    }
}
