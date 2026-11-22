import Foundation
import RiftCore

/// Plain explanations of what common macOS services do, read from a file that
/// ships with Rift, so explaining a connection never sends anything anywhere.
public struct ProcessNotes: Sendable {
    private let notes: [String: String]

    public static let shared: ProcessNotes = {
        guard let url = Bundle.main.url(forResource: "process-notes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return ProcessNotes(notes: [:]) }
        return ProcessNotes(data)
    }()

    private init(notes: [String: String]) { self.notes = notes }

    public init(_ data: Data) {
        let decoded = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        notes = decoded.mapValues { String($0.prefix(400)) }
    }

    /// What an Apple service does. Only code Apple signed as part of macOS
    /// matches, so another app can't borrow a service's description by
    /// using its name. Translations are in the app's ProcessNotes string
    /// table, under the English note.
    public func note(for identity: ProcessIdentity?) -> String? {
        guard case .applePlatform(let code) = identity,
              let note = notes[code.signingIdentifier] else { return nil }
        return Bundle.main.localizedString(forKey: note, value: note, table: "ProcessNotes")
    }
}

public enum ConnectionWebSearch {
    /// A web search for the app and destination, opened in the browser only
    /// when the person asks. Rift sends nothing itself.
    public static func url(identity: ProcessIdentity?, fallbackName: String, host: String?) -> URL? {
        let name: String
        switch identity {
        case .applePlatform(let code):
            let short = code.signingIdentifier.hasPrefix("com.apple.")
                ? String(code.signingIdentifier.dropFirst("com.apple.".count)) : code.signingIdentifier
            name = "macOS " + short
        case .developerID(let code), .appStore(let code):
            name = code.signingIdentifier
        case .otherSigner(_, let identifier):
            name = identifier
        default:
            name = fallbackName
        }
        let terms = [name, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !terms.isEmpty else { return nil }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: String(terms.prefix(200)))]
        return components?.url
    }
}
