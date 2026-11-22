import Foundation
import RiftCore

/// The Public Suffix List, which says where a name stops being a registry
/// suffix like `com` or `co.uk`. Rift bundles a copy and reads it on the Mac,
/// so a domain rule never covers a whole suffix, and "this domain" means the
/// part someone registered: `example.co.uk` for `www.example.co.uk`.
///
/// When the list can't be read, `isAvailable` is false and every domain
/// choice is withheld rather than guessed.
public struct PublicSuffixList: Sendable {
    /// Rules by name, true for registry (ICANN) rules and false for names
    /// that companies asked to list, like `github.io`.
    private let rules: [String: Bool]
    /// `*.ck` is kept as `ck`.
    private let wildcards: [String: Bool]
    /// `!www.ck` is kept as `www.ck`.
    private let exceptions: [String: Bool]

    public var isAvailable: Bool { !rules.isEmpty }
    public var ruleCount: Int { rules.count + wildcards.count + exceptions.count }

    public static let unavailable = PublicSuffixList(rules: [:], wildcards: [:], exceptions: [:])

    /// The copy in the app's resources.
    public static let shared: PublicSuffixList = {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .unavailable
        }
        return PublicSuffixList(text)
    }()

    private init(rules: [String: Bool], wildcards: [String: Bool], exceptions: [String: Bool]) {
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    /// Reads the list's text format. Lines Rift can't represent, such as
    /// names its ASCII check refuses, are skipped.
    public init(_ text: String) {
        var rules: [String: Bool] = [:]
        var wildcards: [String: Bool] = [:]
        var exceptions: [String: Bool] = [:]
        var icann = true
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") {
                if line.contains("===BEGIN PRIVATE DOMAINS===") { icann = false }
                if line.contains("===BEGIN ICANN DOMAINS===") { icann = true }
                continue
            }
            guard let token = line.split(whereSeparator: \.isWhitespace).first else { continue }
            var rule = String(token)
            if rule.hasPrefix("!") {
                rule.removeFirst()
                if let name = try? DomainName.converting(rule) { exceptions[name.ascii] = icann }
            } else if rule.hasPrefix("*.") {
                rule.removeFirst(2)
                if let name = try? DomainName.converting(rule) { wildcards[name.ascii] = icann }
            } else if let name = try? DomainName.converting(rule) {
                rules[name.ascii] = icann
            }
        }
        self.init(rules: rules, wildcards: wildcards, exceptions: exceptions)
    }

    /// The suffix of `name` that anyone can register under. With
    /// `registryOnly`, names companies listed themselves, like `github.io`,
    /// don't count. A name no rule covers falls back to its last label.
    public func publicSuffix(of name: DomainName, registryOnly: Bool = false) -> String {
        let labels = name.ascii.split(separator: ".")
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if let icann = exceptions[candidate], !registryOnly || icann {
                return labels[(start + 1)...].joined(separator: ".")
            }
            if let icann = rules[candidate], !registryOnly || icann { return candidate }
            if start + 1 < labels.count,
               let icann = wildcards[labels[(start + 1)...].joined(separator: ".")],
               !registryOnly || icann {
                return candidate
            }
        }
        return labels.last.map(String.init) ?? name.ascii
    }

    /// The registered domain for `name`, such as `example.co.uk` for
    /// `www.example.co.uk`, or nil when `name` is itself a suffix or the list
    /// is unavailable.
    public func registrableDomain(of name: DomainName) -> DomainName? {
        guard isAvailable else { return nil }
        let suffixLabels = publicSuffix(of: name).split(separator: ".").count
        let labels = name.ascii.split(separator: ".")
        guard labels.count > suffixLabels else { return nil }
        return try? DomainName(labels.suffix(suffixLabels + 1).joined(separator: "."))
    }

    /// Whether a rule for `name` and every name under it would cover a whole
    /// registry, like `com` or `co.uk`. True when the list is unavailable, so
    /// callers refuse rather than guess.
    public func coversWholeRegistry(_ name: DomainName) -> Bool {
        guard isAvailable else { return true }
        return publicSuffix(of: name, registryOnly: true) == name.ascii
    }
}
