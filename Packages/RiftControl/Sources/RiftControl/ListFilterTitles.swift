import Foundation

// The words shown for each filter, sort and range. The raw values stay in
// English, because they identify the choice wherever it's kept.

extension MonitorDecisionFilter {
    public var title: String {
        switch self {
        case .all: String(localized: "All decisions", bundle: .module)
        case .allowed: String(localized: "Allowed", bundle: .module)
        case .denied: String(localized: "Blocked", bundle: .module)
        case .unresolved: String(localized: "No rule applied", bundle: .module)
        }
    }
}

extension MonitorDirectionFilter {
    public var title: String {
        switch self {
        case .all: String(localized: "All directions", bundle: .module)
        case .incoming: String(localized: "Incoming", bundle: .module)
        case .outgoing: String(localized: "Outgoing", bundle: .module)
        }
    }
}

extension MonitorLocalityFilter {
    public var title: String {
        switch self {
        case .all: String(localized: "All networks", bundle: .module)
        case .internet: String(localized: "Internet", bundle: .module)
        case .local: String(localized: "Local network", bundle: .module)
        }
    }
}

extension MonitorOwnerFilter {
    public var title: String {
        switch self {
        case .all: String(localized: "All owners", bundle: .module)
        case .user: String(localized: "Your apps", bundle: .module)
        case .system: String(localized: "System services", bundle: .module)
        case .unknown: String(localized: "Unknown owner", bundle: .module)
        }
    }
}

extension MonitorTimeFilter {
    public var title: String {
        switch self {
        case .twoMinutes: String(localized: "2 minutes", bundle: .module)
        case .tenMinutes: String(localized: "10 minutes", bundle: .module)
        case .all: String(localized: "All history", bundle: .module)
        case .hour: String(localized: "This Hour", bundle: .module)
        case .fiveHours: String(localized: "5 hours", bundle: .module)
        case .day: String(localized: "Today", bundle: .module)
        case .threeDays: String(localized: "3 days", bundle: .module)
        case .week: String(localized: "This Week", bundle: .module)
        case .month: String(localized: "This Month", bundle: .module)
        case .thirtyDays: String(localized: "30 days", bundle: .module)
        }
    }
}

extension RuleListFilter {
    public var title: String {
        switch self {
        case .all: String(localized: "All Rules", bundle: .module)
        case .active: String(localized: "Active", bundle: .module)
        case .denied: String(localized: "Blocked", bundle: .module)
        case .recentlyModified: String(localized: "Recently Modified", bundle: .module)
        case .recentlyUsed: String(localized: "Recently Used", bundle: .module)
        case .temporary: String(localized: "Temporary", bundle: .module)
        case .expired: String(localized: "Expired", bundle: .module)
        case .incoming: String(localized: "Incoming", bundle: .module)
        case .unused: String(localized: "Unused", bundle: .module)
        case .redundant: String(localized: "Redundant", bundle: .module)
        case .unreviewed: String(localized: "Unreviewed", bundle: .module)
        }
    }
}

extension RuleSearchScope {
    public var title: String {
        switch self {
        case .all: String(localized: "All Fields", bundle: .module)
        case .application: String(localized: "App", bundle: .module)
        case .match: String(localized: "Match", bundle: .module)
        case .scope: String(localized: "Scope", bundle: .module)
        case .notes: String(localized: "Notes", bundle: .module)
        }
    }
}

extension RuleActionFilter {
    public var title: String {
        switch self {
        case .all: String(localized: "All Actions", bundle: .module)
        case .allow: String(localized: "Allow", bundle: .module)
        case .deny: String(localized: "Block", bundle: .module)
        case .ask: String(localized: "Ask", bundle: .module)
        case .notify: String(localized: "Notify", bundle: .module)
        case .hide: String(localized: "Hide", bundle: .module)
        }
    }

    /// What VoiceOver says when this filter is on.
    public var showingDescription: String {
        switch self {
        case .all: ""
        case .allow: String(localized: "Showing Allow rules", bundle: .module)
        case .deny: String(localized: "Showing Block rules", bundle: .module)
        case .ask: String(localized: "Showing Ask rules", bundle: .module)
        case .notify: String(localized: "Showing Notify rules", bundle: .module)
        case .hide: String(localized: "Showing Hide rules", bundle: .module)
        }
    }
}

extension RuleWorkspaceSort {
    public var title: String {
        switch self {
        case .automatic: String(localized: "Automatic", bundle: .module)
        case .application: String(localized: "App", bundle: .module)
        case .condition: String(localized: "Condition", bundle: .module)
        case .action: String(localized: "Action", bundle: .module)
        case .modified: String(localized: "Modified", bundle: .module)
        case .usage: String(localized: "Usage", bundle: .module)
        case .precedence: String(localized: "Precedence", bundle: .module)
        }
    }
}
