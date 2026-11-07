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
        waitingPrompts: Int = 0
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
            case .setUp: "Set Up Rift"
            case .openSystemSettings: "Open System Settings"
            case .showStatus: "Show Status"
            case .reviewWaiting: "Review"
            case .resumeRules: "Resume Rules"
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

    /// One line about the person's rules, separate from the filter's health.
    public var rulesSummary: String {
        switch state {
        case .active(.filterOff): "Off."
        case .active, .waiting: "In effect."
        case .rulesAtRisk: "In effect, but temporary rules may not apply."
        case .rulesNotCurrent: "Your latest changes are saved, but they aren’t in effect yet."
        case .allowingEverything: "None are in effect."
        case .configurationUnreadable: "Rift can’t read them."
        default: "Rift can’t confirm they’re in effect."
        }
    }

    /// The rules line with counts, shown only when rules are really in use.
    public func rulesDetail(ruleCount: Int?, blocklistCount: Int?) -> String {
        guard rulesApply, let ruleCount, let blocklistCount else { return rulesSummary }
        if ruleCount == 0, blocklistCount == 0 { return "\(rulesSummary) You have no rules yet." }
        let rules = ruleCount == 1 ? "1 rule" : "\(ruleCount) rules"
        guard blocklistCount > 0 else { return "\(rulesSummary) \(rules)." }
        let lists = blocklistCount == 1 ? "1 blocklist" : "\(blocklistCount) blocklists"
        return "\(rulesSummary) \(rules) and \(lists)."
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
        if input.waitingPrompts > 0 { return waiting(input.waitingPrompts) }
        return active(mode)
    }

    private static let preview = ProtectionStatus(
        state: .preview,
        title: "Preview",
        detail: "This preview shows sample data. Nothing on this Mac changes.",
        tone: .preview, traffic: .unknown, action: nil, symbolName: "eye"
    )

    private static let cannotFilter = ProtectionStatus(
        state: .cannotFilter,
        title: "This copy can’t filter",
        detail: "It isn’t signed with Apple’s network filter permission, so it can’t see or block connections.",
        tone: .attention, traffic: .allAllowed, action: .showStatus, symbolName: "shield.slash"
    )

    private static let checking = ProtectionStatus(
        state: .checking,
        title: "Checking the filter",
        detail: "Rift is checking the filter’s status with macOS.",
        tone: .neutral, traffic: .unknown, action: nil, symbolName: "shield.slash"
    )

    private static func unreadable(hasActivePolicy: Bool) -> ProtectionStatus {
        ProtectionStatus(
            state: .configurationUnreadable,
            title: "Rift can’t read your rules",
            detail: hasActivePolicy
                ? "The filter is still using your last working rules."
                : "Rift can’t confirm any rules are in effect.",
            tone: .attention,
            traffic: hasActivePolicy ? .rulesApply : .unknown,
            action: .showStatus,
            symbolName: "exclamationmark.shield"
        )
    }

    private static let setupNeeded = ProtectionStatus(
        state: .setupNeeded,
        title: "Set up Rift",
        detail: "Rift isn’t filtering yet. All connections are allowed until setup is done.",
        tone: .neutral, traffic: .allAllowed, action: .setUp, symbolName: "shield.slash"
    )

    private static func settingUp(title: String?) -> ProtectionStatus {
        ProtectionStatus(
            state: .settingUp,
            title: title ?? "Updating the filter",
            detail: "Rift can’t confirm your rules are in effect until this finishes.",
            tone: .neutral, traffic: .unknown, action: nil, symbolName: "shield.slash"
        )
    }

    private static let needsApproval = ProtectionStatus(
        state: .needsApproval,
        title: "Approve Rift in System Settings",
        detail: "Open Login Items & Extensions, choose Network Extensions, and turn on Rift. All connections are allowed until you do.",
        tone: .attention, traffic: .allAllowed, action: .openSystemSettings,
        symbolName: "exclamationmark.shield"
    )

    private static let filterTurnedOff = ProtectionStatus(
        state: .filterTurnedOff,
        title: "The filter is off",
        detail: "It’s installed but turned off, so all connections are allowed.",
        tone: .attention, traffic: .allAllowed, action: .showStatus, symbolName: "shield.slash"
    )

    private static func lifecycleProblem(_ message: String) -> ProtectionStatus {
        let statesEffect = message.contains("aren’t being filtered")
        return ProtectionStatus(
            state: .lifecycleProblem,
            title: "Rift needs attention",
            detail: statesEffect ? message : "\(message) Rift can’t confirm connections are being filtered.",
            tone: .attention, traffic: .unknown, action: .showStatus,
            symbolName: "exclamationmark.shield"
        )
    }

    private static let connecting = ProtectionStatus(
        state: .connecting,
        title: "Connecting to the filter",
        detail: "Rift can’t confirm your rules are in effect yet.",
        tone: .neutral, traffic: .unknown, action: nil, symbolName: "shield.slash"
    )

    private static let unreachable = ProtectionStatus(
        state: .unreachable,
        title: "Can’t reach the filter",
        detail: "Rift can’t confirm your rules or ask about new connections.",
        tone: .attention, traffic: .unknown, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let modeUnknown = ProtectionStatus(
        state: .modeUnknown,
        title: "Rift needs attention",
        detail: "Rift can’t confirm how connections are handled.",
        tone: .attention, traffic: .unknown, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let allowingEverything = ProtectionStatus(
        state: .allowingEverything,
        title: "All connections are being allowed",
        detail: "The filter is on but has no rules loaded.",
        tone: .attention, traffic: .allAllowed, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let rulesAtRisk = ProtectionStatus(
        state: .rulesAtRisk,
        title: "Rules are on, with a problem",
        detail: "Your rules are in effect, but the filter can’t save its state, and temporary rules may not apply.",
        tone: .attention, traffic: .rulesApply, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static let rulesNotCurrent = ProtectionStatus(
        state: .rulesNotCurrent,
        title: "Your latest rules aren’t in effect",
        detail: "Your changes are saved, but the filter is still using your previous rules.",
        tone: .attention, traffic: .rulesApply, action: .showStatus,
        symbolName: "exclamationmark.shield"
    )

    private static func waiting(_ count: Int) -> ProtectionStatus {
        ProtectionStatus(
            state: .waiting(count),
            title: "Connections are waiting",
            detail: "Any you don’t answer in time are allowed.",
            tone: .attention, traffic: .rulesApply, action: .reviewWaiting,
            symbolName: "exclamationmark.shield"
        )
    }

    private static func active(_ mode: OperationMode) -> ProtectionStatus {
        switch mode {
        case .alert:
            ProtectionStatus(
                state: .active(mode), title: "Rift is asking",
                detail: "Rift asks about new connections with no rule. If it can’t ask, they’re allowed.",
                tone: .good, traffic: .rulesApply, action: nil, symbolName: "questionmark.circle"
            )
        case .silentAllow:
            ProtectionStatus(
                state: .active(mode), title: "Rift is watching",
                detail: "New connections are allowed unless a rule blocks them.",
                tone: .neutral, traffic: .rulesApply, action: nil, symbolName: "eye"
            )
        case .silentDeny:
            ProtectionStatus(
                state: .active(mode), title: "Rift is blocking",
                detail: "New connections are blocked unless a rule allows them.",
                tone: .good, traffic: .rulesApply, action: nil, symbolName: "xmark.shield"
            )
        case .filterOff:
            ProtectionStatus(
                state: .active(mode), title: "Rules are paused",
                detail: "All connections are allowed and your rules are off.",
                tone: .neutral, traffic: .allAllowed, action: .resumeRules, symbolName: "pause.circle"
            )
        case .degradedFallback:
            modeUnknown
        }
    }
}
