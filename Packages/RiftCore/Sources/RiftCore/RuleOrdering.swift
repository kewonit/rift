/// Ranks rules the way the filter ranks rules that match the same
/// connection, for showing a rule list in precedence order.
public enum RuleOrdering {
    /// Whether `lhs` would win over `rhs` if both matched a connection. A set
    /// is ranked as if its most specific member matched, so this is exact for
    /// single-member rules and an estimate for larger sets.
    public static func precedes(_ lhs: Rule, _ rhs: Rule) -> Bool {
        RulePrecedence.precedes(
            ApplicableRule(rule: lhs, destination: specificity(lhs.destination)),
            ApplicableRule(rule: rhs, destination: specificity(rhs.destination))
        )
    }

    private static func specificity(_ destination: DestinationCondition) -> DestinationSpecificity {
        switch destination {
        case .ipSet(let values):
            guard let narrowest = values.min(by: {
                $0.spanMagnitude.lexicographicallyPrecedes($1.spanMagnitude)
            }) else { return .anyEndpoint }
            return .ip(set: values, matched: narrowest)
        case .exactHostnameSet(let values):
            guard let first = values.first else { return .anyEndpoint }
            return .hostname(set: values, matched: first)
        case .domainSet(let values):
            guard let fewest = values.min(by: { $0.labelCount < $1.labelCount }) else {
                return .anyEndpoint
            }
            return .domain(set: values, matched: fewest)
        case .endpointClass(let value):
            return .endpointClass(value)
        case .anyEndpoint:
            return .anyEndpoint
        }
    }
}
