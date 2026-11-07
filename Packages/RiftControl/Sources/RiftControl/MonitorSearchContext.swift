import RiftCore

/// What the app knows that stored connections don't, so search can find the
/// names shown on screen. Everything here is optional, and lookups stay on this
/// Mac.
public struct MonitorSearchContext: Sendable {
    public var displayNames: [ProcessIdentity: String]
    public var countryCode: (@Sendable (IPAddress) -> String?)?
    public var countryName: (@Sendable (String) -> String?)?

    public init(
        displayNames: [ProcessIdentity: String] = [:],
        countryCode: (@Sendable (IPAddress) -> String?)? = nil,
        countryName: (@Sendable (String) -> String?)? = nil
    ) {
        self.displayNames = displayNames
        self.countryCode = countryCode
        self.countryName = countryName
    }

    public static let none = MonitorSearchContext()
}
