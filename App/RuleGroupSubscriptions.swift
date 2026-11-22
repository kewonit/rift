import Foundation
import Observation
import RiftControl
import RiftCore
import UserNotifications

/// Keeps subscribed rule groups up to date from `.lsrules` files the person
/// chose, as often as they chose. Downloads work like blocklist
/// subscriptions: only addresses the person entered, only over HTTPS, with
/// no cookies and nothing about the Mac. Because a rule group can allow
/// connections, an update's new allow rules stay off until the person
/// approves them, unless they turned that off for the subscription.
@MainActor
@Observable
final class RuleGroupSubscriptions {
    static let shared = RuleGroupSubscriptions()
    private static let storageKey = "ruleGroupSubscriptions"

    private(set) var items: [UUID: RuleGroupSubscription] = [:]
    private(set) var refreshing: Set<UUID> = []
    @ObservationIgnored private weak var controlPlane: ControlPlaneController?
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([RuleGroupSubscription].self, from: data) {
            items = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Starts the regular checks. Safe to call more than once.
    func start(controlPlane: ControlPlaneController) {
        self.controlPlane = controlPlane
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    /// Downloads a file and reads it as a rule group, without changing anything.
    func preview(address: String) async throws -> PendingRuleGroupSubscription {
        let url = try BlocklistSubscriptionAddress.validate(address)
        guard let controlPlane else { throw BlocklistSubscriptionError.invalidAddress }
        guard case .changed(let data, let tag, let modified) = try await BlocklistDownloader.fetch(url) else {
            throw BlocklistSubscriptionError.notAList
        }
        let conversion = try await controlPlane.previewRuleGroup(data, url: url)
        let name = conversion.payload.localGroups.first?.name ?? BlocklistSubscriptionAddress.host(of: url)
        return PendingRuleGroupSubscription(
            url: url, name: name, conversion: conversion, entityTag: tag, lastModified: modified
        )
    }

    /// Adds the previewed rules as a group that stays up to date.
    func subscribe(
        _ pending: PendingRuleGroupSubscription,
        interval: BlocklistUpdateInterval,
        holdsNewAllowRules: Bool
    ) async throws -> (ConfigurationMutationResult, UUID) {
        guard let controlPlane else { throw BlocklistSubscriptionError.invalidAddress }
        let (result, groupID, held) = try await controlPlane.createSubscribedGroup(pending)
        var item = RuleGroupSubscription(
            id: groupID, url: pending.url, interval: interval,
            holdsNewAllowRules: holdsNewAllowRules, lastCheckedAt: Date()
        )
        item.entityTag = pending.entityTag
        item.lastModified = pending.lastModified
        item.pendingRuleIDs = held
        items[groupID] = item
        save()
        return (result, groupID)
    }

    /// Checks one group now. Returns what happened, in a sentence. An
    /// automatic check also notifies when rules are waiting for approval or
    /// the file couldn't be checked, if notifications are on.
    @discardableResult
    func refresh(_ id: UUID, notifies: Bool = false) async -> String {
        guard var item = items[id] else { return String(localized: "This group isn’t a subscription.") }
        guard let controlPlane else { return String(localized: "Rift isn’t ready to check rule groups yet.") }
        guard !refreshing.contains(id) else { return String(localized: "This group is already being checked.") }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        let now = Date()
        do {
            switch try await BlocklistDownloader.fetch(
                item.url, entityTag: item.entityTag, lastModified: item.lastModified
            ) {
            case .notModified:
                item.lastFailure = nil
                item.lastCheckedAt = now
                keep(item)
                return String(localized: "The rule group is up to date.")
            case .changed(let data, let tag, let modified):
                let conversion = try await controlPlane.previewRuleGroup(data, url: item.url)
                let update = try await controlPlane.updateSubscribedGroup(
                    id, incoming: conversion.payload.rules, holdsNewAllowRules: item.holdsNewAllowRules
                )
                item.lastFailure = nil
                item.lastCheckedAt = now
                item.entityTag = tag
                item.lastModified = modified
                if update.merge.changed { item.lastChangedAt = now }
                item.notePending(held: update.merge.heldRuleIDs, groupRules: update.groupRules)
                keep(item)
                if notifies, !update.merge.heldRuleIDs.isEmpty {
                    await notify(String(localized: "Rule group updated"), id: id, detail: update.merge.summary)
                }
                return update.merge.summary
            }
        } catch {
            item.lastFailure = Self.message(for: error)
            item.lastCheckedAt = now
            keep(item)
            if notifies { await notify(String(localized: "A rule group couldn’t be updated"), id: id, detail: item.lastFailure ?? "") }
            return item.lastFailure ?? String(localized: "The rule group couldn’t be checked.")
        }
    }

    /// Turns on the rules an update held. Returns what happened.
    func approvePending(_ id: UUID) async -> String {
        guard var item = items[id], let controlPlane, !item.pendingRuleIDs.isEmpty else {
            return String(localized: "No rules are waiting.")
        }
        do {
            guard let generation = controlPlane.desiredPolicyTuple?.generation else {
                throw ControlPlaneController.RuleCommandError.missingConfiguration
            }
            let result = try await controlPlane.setRulesEnabled(
                Set(item.pendingRuleIDs), enabled: true, expectedGeneration: generation
            )
            let count = item.pendingRuleIDs.count
            item.notePending(groupRules: await controlPlane.rules(inGroup: id) ?? [])
            keep(item)
            let done = String(localized: "Turned on \(count) rules.")
            return result.requiresAttention ? "\(done) \(result.message)" : done
        } catch {
            return ConfigurationLock.message(for: error)
                ?? String(localized: "The rules weren’t turned on. Your rules may have changed, so try again.")
        }
    }

    /// Notices rules the person turned on or removed in Rules.
    func notePendingChanges() async {
        guard let controlPlane else { return }
        for (id, item) in items where !item.pendingRuleIDs.isEmpty {
            guard let rules = await controlPlane.rules(inGroup: id) else { continue }
            var updated = item
            updated.notePending(groupRules: rules)
            if updated != item { keep(updated) }
        }
    }

    private func keep(_ item: RuleGroupSubscription) {
        guard items[item.id] != nil else { return }
        items[item.id] = item
        save()
    }

    func forget(_ id: UUID) {
        guard items.removeValue(forKey: id) != nil else { return }
        save()
    }

    func refreshDue() async {
        guard let controlPlane else { return }
        // A group removed elsewhere, such as in Rules or by a restore, stops updating.
        if let groups = try? await controlPlane.policyDefinitions().groups {
            let existing = Set(groups.map(\.id))
            for id in items.keys where !existing.contains(id) { forget(id) }
        }
        let now = Date()
        for item in items.values where item.isDue(now: now) {
            await refresh(item.id, notifies: true)
        }
    }

    func setInterval(_ interval: BlocklistUpdateInterval, for id: UUID) {
        guard var item = items[id], ConfigurationLock.shared.permits(.byHand) else { return }
        item.interval = interval == .daily ? nil : interval
        keep(item)
    }

    func setHoldsNewAllowRules(_ holds: Bool, for id: UUID) {
        guard var item = items[id], ConfigurationLock.shared.permits(.byHand) else { return }
        item.allowsNewAllowRules = holds ? nil : true
        keep(item)
    }

    static func message(for error: any Error) -> String {
        if let locked = ConfigurationLock.message(for: error) { return locked }
        switch error {
        case RuleGroupSubscriptionError.onlyBlockedDestinations:
            return String(localized: "This file only blocks destinations. Subscribe to it in Settings › Blocklists instead.")
        case RuleGroupSubscriptionError.noUsableRules:
            return String(localized: "None of the file’s rules can apply on this Mac, such as rules for apps that aren’t installed.")
        case BlocklistSubscriptionError.notAList, is LSRulesFileError:
            return String(localized: "The download isn’t a .lsrules rule group file.")
        default:
            return BlocklistSubscriptions.message(for: error)
        }
    }

    /// What a configuration archive keeps.
    var archived: [ArchivedRuleGroupSubscription]? {
        let values = items.values.map(\.archived)
        return values.isEmpty ? nil : values
    }

    /// Replaces the subscriptions with ones from a restored archive. They
    /// haven't been checked on this Mac, so each is checked soon.
    func restore(_ archived: [ArchivedRuleGroupSubscription]?) {
        items = Dictionary(
            (archived ?? []).map { ($0.groupID, RuleGroupSubscription(restoring: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        save()
        Task { await refreshDue() }
    }

    private func notify(_ title: String, id: UUID, detail: String) async {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
        let name = (try? await controlPlane?.policyDefinitions().groups)?.first { $0.id == id }?.name
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = [name.map { DisplaySanitizer.plainText($0) }, detail].compactMap { $0 }.joined(separator: ": ")
        let request = UNNotificationRequest(identifier: "rift-rule-group-\(id.uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(items.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
