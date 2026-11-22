import Foundation
import RiftCore
import RiftIPC

/// Everything Rift knows about its own state, gathered from the filter
/// lifecycle, the connection to the filter and the saved configuration.
public struct ProtectionInputs: Sendable, Equatable {
    public enum Controller: Sendable, Equatable {
        case starting
        case connected(ProviderReadiness)
        case unreachable
        case failed
    }

    public var isPreview: Bool
    public var buildCanFilter: Bool
    /// `nil` until macOS has reported the filter's status.
    public var lifecycle: LifecycleState?
    public var lifecycleTitle: String?
    public var controller: Controller
    public var filterServiceConfirmed: Bool
    public var hasActivePolicy: Bool
    public var desiredKnown: Bool
    public var rulesMatchDesired: Bool
    /// `nil` when the configuration can't be read.
    public var mode: OperationMode?
    public var configurationUnreadable: Bool
    public var waitingPrompts: Int
    /// Waiting connections nobody answers are blocked, not allowed.
    public var unansweredBlocked: Bool
    /// The filter says it's on, but no connection has reached Rift for a
    /// while although the network is up. See `FilterLiveness`.
    public var filterSilent: Bool

    public init(
        isPreview: Bool = false,
        buildCanFilter: Bool = true,
        lifecycle: LifecycleState? = nil,
        lifecycleTitle: String? = nil,
        controller: Controller = .starting,
        filterServiceConfirmed: Bool = false,
        hasActivePolicy: Bool = false,
        desiredKnown: Bool = false,
        rulesMatchDesired: Bool = false,
        mode: OperationMode? = nil,
        configurationUnreadable: Bool = false,
        waitingPrompts: Int = 0,
        unansweredBlocked: Bool = false,
        filterSilent: Bool = false
    ) {
        self.isPreview = isPreview
        self.buildCanFilter = buildCanFilter
        self.lifecycle = lifecycle
        self.lifecycleTitle = lifecycleTitle
        self.controller = controller
        self.filterServiceConfirmed = filterServiceConfirmed
        self.hasActivePolicy = hasActivePolicy
        self.desiredKnown = desiredKnown
        self.rulesMatchDesired = rulesMatchDesired
        self.mode = mode
        self.configurationUnreadable = configurationUnreadable
        self.waitingPrompts = waitingPrompts
        self.unansweredBlocked = unansweredBlocked
        self.filterSilent = filterSilent
    }
}

/// The single answer to "what is Rift doing right now?", shared by the Status
/// page, the menu-bar panel and the Map banner so they can't disagree.
public struct ProtectionStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case preview
        case cannotFilter
        case checking
        case configurationUnreadable
        case setupNeeded
        case settingUp
        case needsApproval
        case filterTurnedOff
        case lifecycleProblem
        case connecting
        case unreachable
        case modeUnknown
        case allowingEverything
        case rulesAtRisk
        case rulesNotCurrent
        case filterSilent
        case waiting(Int)
        case active(OperationMode)
    }

    public enum Tone: Sendable, Equatable {
        /// Something can actually be blocked right now.
        case good
        /// Working as chosen, but not blocking by default.
        case neutral
        case attention
        case preview
    }

    public enum Traffic: Sendable, Equatable {
        case rulesApply
        case allAllowed
        case unknown
    }

    public enum Action: Sendable, Equatable {
        case setUp
        case openSystemSettings
        case showStatus
        case reviewWaiting
        case resumeRules

        public var title: String {
            switch self {
            case .setUp: String(localized: "Set Up Rift", bundle: .module)
            case .openSystemSettings: String(localized: "Open System Settings", bundle: .module)
            case .showStatus: String(localized: "Show Status", bundle: .module)
            case .reviewWaiting: String(localized: "Review", bundle: .module)
            case .resumeRules: String(localized: "Resume Rules", bundle: .module)
            }
        }
    }

    public let state: State
    public let title: String
    public let detail: String
    public let tone: Tone
    public let traffic: Traffic
    public let action: Action?
    public let symbolName: String

    /// Whether the Map should show this state, because it needs a decision or
    /// changes what the person can rely on.
    public var showsBanner: Bool {
        switch state {
        case .preview, .checking, .settingUp, .connecting, .waiting, .active: false
        default: true
        }
    }

    /// Whether connections can appear at all. An empty list means something
    /// different when the filter isn't there to see them.
    public var canShowActivity: Bool {
        switch state {
        case .preview, .active, .waiting, .connecting, .rulesAtRisk, .rulesNotCurrent,
             .allowingEverything, .modeUnknown, .filterSilent:
            true
        default:
            false
        }
    }

    /// One line about the person's rules, separate from the filter's health.
    public var rulesSummary: String {
        switch state {
        case .active(.filterOff): String(localized: "Off.", bundle: .module)
        case .active, .waiting: String(localized: "In effect.", bundle: .module)
        case .rulesAtRisk: String(localized: "In effect, but temporary rules may not apply.", bundle: .module)
        case .rulesNotCurrent: String(localized: "Your latest changes are saved, but they aren’t in effect yet.", bundle: .module)
        case .allowingEverything: String(localized: "None are in effect.", bundle: .module)
        case .configurationUnreadable: String(localized: "Rift can’t read them.", bundle: .module)
        default: String(localized: "Rift can’t confirm they’re in effect.", bundle: .module)
        }
    }

    /// The rules line with counts, shown only when rules are really in use.
    public func rulesDetail(ruleCount: Int?, blocklistCount: Int?) -> String {
        guard rulesApply, let ruleCount, let blocklistCount else { return rulesSummary }
        if ruleCount == 0, blocklistCount == 0 {
            return String(localized: "\(rulesSummary) You have no rules yet.", bundle: .module)
        }
        let rules = String(localized: "\(ruleCount) rules", bundle: .module)
        guard blocklistCount > 0 else {
            return String(localized: "\(rulesSummary) \(rules).", bundle: .module,
                          comment: "The rules summary, then a count of rules")
        }
        let lists = String(localized: "\(blocklistCount) blocklists", bundle: .module)
        return String(localized: "\(rulesSummary) \(rules) and \(lists).", bundle: .module,
                      comment: "The rules summary, then counts of rules and blocklists")
    }

    private var rulesApply: Bool {
        switch state {
        case .active(.filterOff): false
        case .active, .waiting, .rulesAtRisk: true
        default: false
        }
    }

    public static func resolve(_ input: ProtectionInputs) -> ProtectionStatus {
        if input.isPreview { return preview }
        if !input.buildCanFilter { return cannotFilter }
        guard let lifecycle = input.lifecycle else { return checking }
        if input.configurationUnreadable { return unreadable(hasActivePolicy: input.hasActivePolicy) }
        switch lifecycle {
        case .notInstalled: return setupNeeded
        case .activating, .active, .savingFilterConfiguration, .stale, .replacing, .uninstalling:
            return settingUp(title: input.lifecycleTitle)
        case .awaitingApproval: return needsApproval
        case .disabled: return filterTurnedOff
        case .denied(let message), .failed(let message): return lifecycleProblem(message)
        case .enabled: return resolveEnabled(input)
        }
    }

    private static func resolveEnabled(_ input: ProtectionInputs) -> ProtectionStatus {
        switch input.controller {
        case .starting, .connected(.starting): return connecting
        case .unreachable, .failed: return unreachable
        case .connected(.degradedNoPolicy): return allowingEverything
        case .connected(.degradedPersistence):
            return input.hasActivePolicy ? rulesAtRisk : allowingEverything
        case .connected(.unavailable):
            return input.hasActivePolicy ? unreachable : allowingEverything
        case .connected(.ready): break
        }
        guard input.desiredKnown else { return connecting }
        guard input.hasActivePolicy else { return allowingEverything }
        guard input.rulesMatchDesired else { return rulesNotCurrent }
        guard input.filterServiceConfirmed else { return connecting }
        guard let mode = input.mode, mode != .degradedFallback else { return modeUnknown }
        if input.filterSilent, mode != .filterOff { return filterSilent }
        if input.waitingPrompts > 0 {
            return waiting(input.waitingPrompts, blocked: input.unansweredBlocked)
        }
        return active(mode)
    }

    private static let filterSilent = ProtectionStatus(
        state: .filterSilent,
        title: String(localized: "Rift isn’t seeing connections", bundle: .module),
        detail: String(localized: "The filter says it’s on, but no connection has reached Rift for \(Int(FilterLiveness.silenceThreshold / 60)) minutes while the network is up. Your rules may not be applying.", bundle: .module),
        tone: .attention, traffic: .unknown, action: .showStatus, symbolName: "exclamationmark.shield"
    )

    private static let preview = ProtectionStatus(
        state: .preview,
        title: String(localized: "Preview", bundle: .module),
        detail: String(localized: "This preview shows sample data. Nothing on this Mac changes.", bundle: .module),
        tone: .preview, traffic: .unknown, action: nil, symbolName: "eye"
    )

    private static let cannotFilter = ProtectionStatus(
        state: .cannotFilter,
        title: String(localized: "This copy can’t filter", bundle: .module),
        detail: String(localized: "It isn’t signed with Apple’s network filter permission, so it can’t see or block connections.", bundle: .module),
        tone: .attention, traffic: .allAllowed, action: .showStatus, symbolName: "shield.slash"
    )

    private static let checking = ProtectionStatus(
        state: .checking,
        title: String(localized: "Checking the filter", bundle: .module),
        detail: String(localized: "Rift is checking the filter’s status with macOS.", bundle: .module),
        tone: .neutral, traffic: .unknown, action: nil, symbolName: "shield.slash"
    )

    private static func unreadable(hasActivePolicy: Bool) -> ProtectionStatus {
        ProtectionStatus(
            state: .configurationUnreadable,
            title: String(localized: "Rift can’t read your rules", bundle: .module),
            detail: hasActivePolicy
                ? String(localized: "The filter is still using your last working rules.", bundle: .module)
                : String(localized: "Rift can’t confirm any rules are in effect.", bundle: .module),
            tone: .attention,
            traffic: hasActivePolicy ? .rulesApply : .unknown,
            action: .showStatus,
            symbolName: "exclamationmark.shield"
        )
    }

    private static let setupNeeded = ProtectionStatus(
        state: .setupNeeded,
        title: String(localized: "Set up Rift", bundle: .module),
        detail: String(localized: "Rift isn’t filtering yet. All connections are allowed until setup is done.", bundle: .module),
        tone: .neutral, traffic: .allAllowed, action: .setUp, symbolName: "shield.slash"
    )

    private static func settingUp(title: String?) -> ProtectionStatus {
        ProtectionStatus(
            state: .settingUp,
            title: title ?? String(localized: "Updating the filter", bundle: .module),
            detail: String(localized: "Rift can’t confirm your rules are in effect until this finishes.", bundle: .module),
            tone: .neutral, traffic: .unknown, action: nil, symbolName: "shield.slash"
        )
    }

    private static let needsApproval = ProtectionStatus(
        state: .needsApproval,
        title: String(localized: "Approve Rift in System Settings", bundle: .module),
        detail: String(localized: "Open Login Items & Extensions, choose Network Extensions, and turn on Rift. All connections are allowed until you do.", bundle: .module),
        tone: .attention, traffic: .allAllowed, action: .openSystemSettings,
        symbolName: "exclamationmark.shield"
    )

    private static let filterTurnedOff = ProtectionStatus(
        state: .filterTurnedOff,
        title: String(localized: "The filter is off", bundle: .module),
        detail: String(localized: "It’s installed but turned off, so all connections are allowed.", bundle: .module),
        tone: .attention, traffic: .allAllowed, action: .showStatus, symbolName: "shield.slash"
    )

    private static func lifecycleProblem(_ message: String) -> ProtectionStatus {
        // The filter's own messages say when connections aren't filtered.
        let statesEffect = message.contains(String(
            localized: "aren’t being filtered", bundle: .module,
            comment: "Must appear word for word in the filter messages that say connections aren’t being filtered"
        ))
        return ProtectionStatus(
            state: .lifecycleProblem,
            title: String(localized: "Rift needs attention", bundle: .module),
            detail: statesEffect
                ? message
                : String(localized: "\(message) Rift can’t confirm connections are being filtered.", bundle: .module),
            tone: .attention, traffic: .unknown, action: .showStatus,
            symbolName: "exclamationmark.shield"
        )
    }

    private static let connecting = ProtectionStatus(
        state: .connecting,
        title: String(localized: "Connecting to the filter", bundle: .module),
        detail: String(localized: "Rift can’t confirm your rules are in effect yet.", bundle: .module),
        tone: .neutral, traffic: .unknown, action: nil, symbolName: "shield.slash"
    )

    private static let unreachable = ProtectionStatus(
        state: .unreachable,
        title: String(localized: "Can’t reach the filter", bundle: .module),
        detail: String(localized: "Rift can’t confirm your rules or ask about new connections.", bundle: .module),
        tone: .attention, traffic: .unknown, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let modeUnknown = ProtectionStatus(
        state: .modeUnknown,
        title: String(localized: "Rift needs attention", bundle: .module),
        detail: String(localized: "Rift can’t confirm how connections are handled.", bundle: .module),
        tone: .attention, traffic: .unknown, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let allowingEverything = ProtectionStatus(
        state: .allowingEverything,
        title: String(localized: "All connections are being allowed", bundle: .module),
        detail: String(localized: "The filter is on but has no rules loaded.", bundle: .module),
        tone: .attention, traffic: .allAllowed, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let rulesAtRisk = ProtectionStatus(
        state: .rulesAtRisk,
        title: String(localized: "Rules are on, with a problem", bundle: .module),
        detail: String(localized: "Your rules are in effect, but the filter can’t save its state, and temporary rules may not apply.", bundle: .module),
        tone: .attention, traffic: .rulesApply, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let rulesNotCurrent = ProtectionStatus(
        state: .rulesNotCurrent,
        title: String(localized: "Your latest rules aren’t in effect", bundle: .module),
        detail: String(localized: "Your changes are saved, but the filter is still using your previous rules.", bundle: .module),
        tone: .attention, traffic: .rulesApply, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static func waiting(_ count: Int, blocked: Bool) -> ProtectionStatus {
        ProtectionStatus(
            state: .waiting(count),
            title: String(localized: "Connections are waiting", bundle: .module),
            detail: blocked
                ? String(localized: "Any you don’t answer in time are blocked.", bundle: .module)
                : String(localized: "Any you don’t answer in time are allowed.", bundle: .module),
            tone: .attention, traffic: .rulesApply, action: .reviewWaiting,
            symbolName: "exclamationmark.shield"
        )
    }

    private static func active(_ mode: OperationMode) -> ProtectionStatus {
        switch mode {
        case .alert:
            ProtectionStatus(
                state: .active(mode), title: String(localized: "Rift is asking", bundle: .module),
                detail: String(localized: "Rift asks about new connections with no rule. If it can’t ask, they’re allowed.", bundle: .module),
                tone: .good, traffic: .rulesApply, action: nil, symbolName: "questionmark.circle"
            )
        case .silentAllow:
            ProtectionStatus(
                state: .active(mode), title: String(localized: "Rift is watching", bundle: .module),
                detail: String(localized: "New connections are allowed unless a rule blocks them.", bundle: .module),
                tone: .neutral, traffic: .rulesApply, action: nil, symbolName: "eye"
            )
        case .silentDeny:
            ProtectionStatus(
                state: .active(mode), title: String(localized: "Rift is blocking", bundle: .module),
                detail: String(localized: "New connections are blocked unless a rule allows them.", bundle: .module),
                tone: .good, traffic: .rulesApply, action: nil, symbolName: "xmark.shield"
            )
        case .filterOff:
            ProtectionStatus(
                state: .active(mode), title: String(localized: "Rules are paused", bundle: .module),
                detail: String(localized: "All connections are allowed and your rules are off.", bundle: .module),
                tone: .neutral, traffic: .allAllowed, action: .resumeRules, symbolName: "pause.circle"
            )
        case .degradedFallback:
            modeUnknown
        }
    }
}
