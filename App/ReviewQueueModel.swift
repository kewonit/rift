import Foundation
import Observation
import RiftControl
import RiftCore
import UserNotifications

/// The Review list: apps that connected with no rule over the last week,
/// and connections whose alert went unanswered. It reads history, so it has
/// something to show in Allow and Watch, where nothing ever asks.
@MainActor
@Observable
final class ReviewQueueModel {
    static let window: TimeInterval = 7 * 86_400
    /// How long Allow and Watch runs before Rift suggests a review.
    static let firstReviewDelay: TimeInterval = 86_400
    nonisolated static let notificationKey = "review"

    private enum Key {
        static let dismissed = "reviewDismissedApps"
        static let watchingSince = "reviewWatchingSince"
        static let notified = "reviewSuggested"
    }

    private(set) var queue = ReviewQueue(apps: [], unanswered: [])
    private(set) var loaded = false
    private(set) var applying: Set<String> = []
    var isPresented = false

    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private var dismissed: [String: Date]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false

    var count: Int { queue.apps.count + queue.unanswered.count }

    init() {
        let data = UserDefaults.standard.data(forKey: Key.dismissed)
        dismissed = data.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    /// Refreshes every few minutes. Safe to call more than once.
    func start(session: AppSession) {
        self.session = session
        guard loop == nil else { return }
#if DEBUG
        if session.isUIFixture, FixturePreviewOptions.opensReview { isPresented = true }
#endif
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(session.isUIFixture ? 1 : 20))
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    func refresh() async {
        guard let controlPlane = session?.controlPlane, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let rows = await rows(from: controlPlane)
        let candidates = ReviewQueue.candidates(in: rows)
        let coverage = (try? await controlPlane.monitorRuleCoverage(for: candidates)) ?? [:]
        let undecided = candidates.filter { (coverage[$0.id]?.state ?? .noRule) == .noRule }.map(\.id)
        queue = ReviewQueue.build(rows: rows, stillUndecided: Set(undecided), dismissed: dismissed)
        loaded = true
        suggestReviewIfDue(mode: controlPlane.currentMode)
    }

    /// Hides an app until it connects somewhere it hadn't before.
    func dismiss(_ app: ReviewQueue.App) {
        dismissed[app.id] = Date()
        if let data = try? JSONEncoder().encode(dismissed) {
            UserDefaults.standard.set(data, forKey: Key.dismissed)
        }
        queue = ReviewQueue(apps: queue.apps.filter { $0.id != app.id }, unanswered: queue.unanswered)
    }

    /// Allows or blocks an app everywhere, the same way the Map does.
    func decide(_ action: FilterAction, app: ReviewQueue.App, name: String) {
        apply(action, row: app.row, breadth: .allDestinations, name: name, itemID: app.id)
    }

    /// Allows or blocks one unanswered destination, by domain when it has one.
    func decide(_ action: FilterAction, unanswered item: ReviewQueue.Unanswered, name: String) {
        decide(action, destinationOf: item.row, name: name, itemID: item.id)
    }

    /// Allows or blocks a connection's destination, by domain when it has
    /// one, as a notification's buttons do.
    func decide(_ action: FilterAction, destinationOf row: MonitorEventRow, name: String, itemID: String? = nil) {
        let options = MonitorRuleScope.options(for: [row])
        guard let breadth = [MonitorRuleBreadth.thisDomain, .thisHost, .exactConnection]
            .first(where: options.contains) else { return }
        apply(action, row: row, breadth: breadth, name: name, itemID: itemID ?? row.id)
    }

    private func apply(
        _ action: FilterAction,
        row: MonitorEventRow,
        breadth: MonitorRuleBreadth,
        name: String,
        itemID: String
    ) {
        guard let controlPlane = session?.controlPlane, !applying.contains(itemID) else { return }
        applying.insert(itemID)
        let results = controlPlane.actionResults
        Task {
            defer { applying.remove(itemID) }
            do {
                let change = try await controlPlane.applyMonitorRule(
                    for: row, action: action, breadth: breadth, duration: .always
                )
                let sentence = RulePlainLanguage.change(
                    action: action,
                    application: name,
                    destination: MonitorRuleScope.phrase(
                        breadth, host: ReviewQueue.destinationLabel(row),
                        domain: MonitorRuleScope.domain(for: row)?.ascii
                    ),
                    port: nil,
                    incoming: row.event.flow.direction == .incoming,
                    lasting: nil
                )
                if let result = change.result {
                    results.post(
                        result.requiresAttention ? "\(sentence) \(result.message)" : sentence,
                        tone: result.requiresAttention ? .pending : .success,
                        ruleIDs: change.ruleIDs, offersUndo: true
                    )
                } else {
                    results.post(action == .deny ? "This is already blocked." : "This is already allowed.", ruleIDs: change.ruleIDs)
                }
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                results.post("A blocklist blocks part of this. Allow it from the Map, where Rift can confirm the change.", tone: .failure)
            } catch ControlPlaneController.RuleCommandError.overriddenByRule(let ruleID) {
                results.post(
                    "Nothing changed, because another rule still decides this connection.",
                    tone: .failure, ruleIDs: ruleID.map { [$0] } ?? []
                )
            } catch {
                results.post("The rule wasn’t added. Try again after Rift reconnects.", tone: .failure)
            }
            await refresh()
        }
    }

    private func rows(from controlPlane: ControlPlaneController) async -> [MonitorEventRow] {
#if DEBUG
        if session?.isUIFixture == true { return MonitorFixtureData.rows }
#endif
        guard controlPlane.persistentHistoryEnabled, let history = controlPlane.history,
              let window = MonitorTimeWindow(start: Date().addingTimeInterval(-Self.window), end: nil) else {
            return controlPlane.recentActivityRows
        }
        return (try? await history.monitorSnapshot(maximum: 50_000, window: window).rows) ?? []
    }

    /// After a day in Allow and Watch, suggests a review once.
    private func suggestReviewIfDue(mode: OperationMode) {
        let defaults = UserDefaults.standard
        guard mode == .silentAllow else {
            defaults.removeObject(forKey: Key.watchingSince)
            return
        }
        let now = Date()
        guard let since = defaults.object(forKey: Key.watchingSince) as? Date else {
            defaults.set(now, forKey: Key.watchingSince)
            return
        }
        guard now.timeIntervalSince(since) >= Self.firstReviewDelay,
              !defaults.bool(forKey: Key.notified), !queue.apps.isEmpty else { return }
        defaults.set(true, forKey: Key.notified)
        let content = UNMutableNotificationContent()
        content.title = "Review what connected"
        let apps = queue.apps.count
        content.body = apps == 1
            ? "1 app connected with no rule. Allow or block it in one click."
            : "\(apps) apps connected with no rule. Allow or block each in one click."
        content.userInfo = [Self.notificationKey: true]
        let request = UNNotificationRequest(identifier: "rift-review", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}

/// What the Map banner and the menu panel say about the Review list.
enum ReviewBannerCopy {
    static func message(_ queue: ReviewQueue) -> String {
        let apps = queue.apps.count
        let unanswered = queue.unanswered.count
        var parts: [String] = []
        if apps > 0 { parts.append(apps == 1 ? "1 app connected with no rule" : "\(apps) apps connected with no rule") }
        if unanswered > 0 {
            parts.append(unanswered == 1 ? "1 alert went unanswered" : "\(unanswered) alerts went unanswered")
        }
        return parts.joined(separator: ", and ")
    }
}
