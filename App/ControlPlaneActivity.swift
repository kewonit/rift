import RiftControl
import RiftIPC
import Foundation

extension ControlPlaneController {
    func requestActivitySubscriptionUpdate() {
        guard !isUIFixture else { return }
        let mode: ActivityCaptureMode = persistentHistoryEnabled ? .persistent : (monitorIsVisible ? .recent : .off)
        let capacity = mode == .recent ? (visibleMonitorCount > 0 ? Self.minimalFlowLimit : 5) : 0
        let notify = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        if desiredActivitySubscription.mode != mode || desiredActivitySubscription.maximumRecentConnections != capacity
            || desiredActivitySubscription.notifyImplicitDecisions != notify {
            desiredActivitySubscription = ActivitySubscription(
                id: mode == .persistent && desiredActivitySubscription.mode == .persistent
                    ? desiredActivitySubscription.id : UUID(),
                mode: mode, maximumRecentConnections: capacity, notifyImplicitDecisions: notify
            )
            if isMinimalActivity { transientHistory = TransientHistoryBuffer(maximumFlows: max(1, capacity)) }
            clearRecentActivity()
        }
        activityDrain.setVisible(mode != .off)
        if mode == .off { activityDrain.stop() }
        guard supportsActivitySubscriptions, activitySubscriptionTask == nil else { return }
        let generation = activityConnectionGeneration
        activitySubscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == activityConnectionGeneration { activitySubscriptionTask = nil } }
            while !Task.isCancelled, generation == activityConnectionGeneration,
                  supportsActivitySubscriptions, appliedActivitySubscription != desiredActivitySubscription {
                let subscription = desiredActivitySubscription
                do {
                    let connectionID = try await client.connect()
                    try await client.setActivitySubscription(subscription)
                    try await client.requireCurrentConnection(connectionID)
                    guard generation == activityConnectionGeneration else { return }
                    appliedActivitySubscription = subscription
                } catch { return }
            }
            guard generation == activityConnectionGeneration else { return }
            scheduleActivityDrain(immediate: true)
        }
    }

    func resetActivityConnection() {
        activityConnectionGeneration &+= 1
        activitySubscriptionTask?.cancel()
        activitySubscriptionTask = nil
        appliedActivitySubscription = nil
        supportsActivitySubscriptions = false
        attentionDrainPending = false
        promptResyncPending = false
        activityDrain.stop()
        clearRecentActivity()
    }

    func clearRecentActivity() {
        activityExpiryTask?.cancel()
        activityExpiryTask = nil
        recentActivity = nil
        if !recentActivityRows.isEmpty {
            recentActivityRows.removeAll(keepingCapacity: false)
            recordRuntimeActivity(true)
        }
    }

    func resumeRuntimeCollection() async {
        if supportsActivitySubscriptions {
            requestActivitySubscriptionUpdate()
            await drainRuntimeAttention(resyncPrompts: true)
            scheduleActivityDrain(immediate: true)
        } else {
            await drainRuntimeData()
        }
    }

    func scheduleActivityDrain(immediate: Bool = false) {
        guard supportsActivitySubscriptions, desiredActivitySubscription.mode != .off else { return }
        activityDrain.request(immediate: immediate) { [weak self] in
            await self?.drainRuntimeActivity()
        }
    }

    func drainRuntimeAttention(resyncPrompts: Bool = false) async {
        guard supportsActivitySubscriptions else { return }
        attentionDrainPending = true
        promptResyncPending = promptResyncPending || resyncPrompts
        guard !attentionDrainRunning else { return }
        attentionDrainRunning = true
        defer {
            attentionDrainRunning = false
            if attentionDrainPending { Task { [weak self] in await self?.drainRuntimeAttention() } }
        }
        let generation = activityConnectionGeneration
        while attentionDrainPending, generation == activityConnectionGeneration {
            attentionDrainPending = false
            let resync = promptResyncPending
            promptResyncPending = false
            do {
                let connectionID = try await client.connect()
                let batch = try await client.drainAttention(resyncPrompts: resync)
                try await client.requireCurrentConnection(connectionID)
                guard generation == activityConnectionGeneration else { return }
                guard batch.providerEpoch == lastHandshake?.providerEpoch else {
                    requestRuntimeControlRefresh()
                    return
                }
                mergeIncomingPrompts(batch.prompts, now: Date())
                retainActivePrompts(batch.activePromptNonces)
                if let deniedAt = batch.recentDenyAt { recordRecentDeny(at: deniedAt) }
                await notifications.route(batch.notifications)
                if batch.prompts.count == 32 || batch.notifications.count == 64 {
                    attentionDrainPending = true
                }
            } catch { return }
        }
    }

    private func drainRuntimeActivity() async {
        guard let subscription = appliedActivitySubscription,
              subscription == desiredActivitySubscription, subscription.mode != .off else { return }
        let generation = activityConnectionGeneration
        let epoch = lastHandshake?.providerEpoch
        do {
            let connectionID = try await client.connect()
            if subscription.mode == .recent {
                let snapshot = try await client.recentActivity()
                try await client.requireCurrentConnection(connectionID)
                guard !Task.isCancelled, generation == activityConnectionGeneration,
                      subscription == desiredActivitySubscription, snapshot.subscriptionID == subscription.id else { return }
                guard snapshot.providerEpoch == epoch, epoch == lastHandshake?.providerEpoch else {
                    requestRuntimeControlRefresh()
                    return
                }
                guard recentActivity != snapshot else { return }
                var buffer = TransientHistoryBuffer()
                buffer.ingest(RuntimeEventBatch(providerEpoch: snapshot.providerEpoch, events: snapshot.events, droppedCount: 0))
                let now = Date()
                let rows = buffer.page(limit: subscription.maximumRecentConnections).filter {
                    $0.event.flow.observedAt.addingTimeInterval(ActivitySubscription.recentLifetime) > now
                }
                recentActivity = snapshot
                if recentActivityRows != rows {
                    recentActivityRows = rows
                    recordRuntimeActivity(true)
                }
                activityExpiryTask?.cancel()
                if let expiry = snapshot.nextExpiry {
                    activityExpiryTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
                        catch { return }
                        guard let self, subscription == desiredActivitySubscription else { return }
                        scheduleActivityDrain(immediate: true)
                    }
                }
            } else {
                for _ in 0..<32 {
                    let batch = try await client.drainEvents()
                    try await client.requireCurrentConnection(connectionID)
                    guard !Task.isCancelled, generation == activityConnectionGeneration,
                          subscription.id == desiredActivitySubscription.id else { return }
                    let lossChanged = recordRuntimeLoss(batch.droppedCount)
                    await retainAndPersist(batch, runtimeInstanceID: lastHandshake?.runtimeInstanceID)
                    recordRuntimeActivity(!batch.events.isEmpty || lossChanged)
                    if batch.events.count < IPCProtocolLimits.maximumEventBatchCount { break }
                }
                if let runtimeID = lastHandshake?.runtimeInstanceID {
                    recordRuntimeActivity(await recordAuthenticatedRuntimeDrain(runtimeID, at: Date()))
                }
            }
        } catch {}
    }

    func drainRuntimeData() async {
        var successfulRuntimeDrain: (id: UUID, at: Date)?
        for _ in 0..<32 {
            let runtimeInstanceID = lastHandshake?.runtimeInstanceID
            let incoming: [PromptRequest]
            let batch: RuntimeEventBatch
            do {
                incoming = try await client.drainPrompts()
                batch = try await client.drainEvents()
            } catch {
                break
            }
            if let runtimeInstanceID {
                successfulRuntimeDrain = (runtimeInstanceID, Date())
            }
            let notificationEvents = (try? await client.drainNotifications()) ?? []
            mergeIncomingPrompts(incoming, now: Date())
            reconcilePendingPrompts(with: batch)
            let lossChanged = recordRuntimeLoss(batch.droppedCount)
            recordRecentDeny(from: batch.events)
            await notifications.route(batch.events)
            await notifications.route(notificationEvents)
            await retainAndPersist(batch, runtimeInstanceID: runtimeInstanceID)
            if isMinimalActivity, monitorIsVisible {
                // Compatibility with a peer that cannot stop telemetry upstream yet.
                transientHistory.ingest(batch)
                recentActivityRows = Array(transientHistory.page(limit: Self.minimalFlowLimit).filter {
                    $0.event.flow.observedAt.addingTimeInterval(ActivitySubscription.recentLifetime) > Date()
                }.prefix(visibleMonitorCount > 0 ? Self.minimalFlowLimit : 5))
            }
            recordRuntimeActivity(!batch.events.isEmpty || lossChanged)
            if incoming.isEmpty && batch.events.isEmpty && notificationEvents.isEmpty { break }
        }
        if let successfulRuntimeDrain {
            recordRuntimeActivity(await recordAuthenticatedRuntimeDrain(
                successfulRuntimeDrain.id,
                at: successfulRuntimeDrain.at
            ))
        }
    }

    private func recordAuthenticatedRuntimeDrain(_ runtimeInstanceID: UUID, at date: Date) async -> Bool {
        guard persistentHistoryEnabled, let history else { return false }
        do {
            let transition = try await history.recordAuthenticatedRuntimeDrain(
                runtimeInstanceID: runtimeInstanceID,
                at: date
            )
            if transition.detectedRestart {
                do { try await repository?.markUsagePartial() }
                catch {
                    recordStartupIssue("Rule usage counts may be incomplete because Rift couldn’t save them after the filter restarted.")
                }
            }
            return transition.detectedRestart
        } catch {
            recordStartupIssue("Some activity may be missing because Rift couldn’t save it after the filter restarted.")
            return false
        }
    }
}
