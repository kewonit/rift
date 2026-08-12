import AbyssControl
import AbyssCore
import AppKit
import SwiftUI

struct MonitorView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var session: AppSession
    @State private var query = MonitorQueryState()
    @State private var queryNow: Date
    @State private var allRows: [MonitorEventRow] = []
    @State private var displayed: [MonitorDisplayRow] = []
    @State private var mapRows: [MonitorDisplayRow] = []
    @State private var summary = MonitorSummarySnapshot.empty
    @State private var rowsAreComplete = true
    @State private var historyCoverage = HistoryCoverageSnapshot.unavailable
    @State private var geography: [String: GeoResolution] = [:]
    @State private var coverages: [String: MonitorRuleCoverage] = [:]
    @State private var visibleLimit = 1_000
    @State private var pinnedDisplayRow: MonitorDisplayRow?
    @State private var selectionID: String?
    @State private var selectedEventID: String?
    @State private var applyingEventID: String?
    @State private var pendingManagedListOverride: MonitorHierarchyNode?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showingMap = false
    @State private var showingMapDisclosure = false
    @State private var mapOrigin: CoarseMapOrigin?
    @State private var isPlacingOrigin = false
    @State private var queryTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var activeRefreshID = UUID()
    @State private var activeQueryRequestID = MonitorQueryRequestID()
    @State private var monitorIsReady = false

    init(session: AppSession) {
        self.session = session
#if DEBUG
        _queryNow = State(initialValue: session.isUIFixture
            ? MonitorFixtureData.referenceNow : Date())
#else
        _queryNow = State(initialValue: Date())
#endif
    }

    private var visibleRows: [MonitorDisplayRow] {
        var rows = Array(displayed.prefix(visibleLimit))
        if let pinnedDisplayRow, !rows.contains(where: { $0.id == pinnedDisplayRow.id }) {
            rows.append(pinnedDisplayRow)
        }
        return rows
    }

    private var hierarchy: [MonitorHierarchyNode] {
        MonitorHierarchyBuilder.build(visibleRows, lens: query.lens, coverages: coverages)
    }
    private var selectedNode: MonitorHierarchyNode? {
        selectionID.flatMap { MonitorHierarchyBuilder.node(withID: $0, in: hierarchy) }
    }

    private var selectedRow: MonitorEventRow? {
        guard let eventID = selectedNode?.eventID ?? selectedNode?.ruleSeedEventID else {
            return nil
        }
        return allRows.first { $0.id == eventID }
    }
    private var geolocation: GeolocationController { session.geolocation }
    private var canShowMap: Bool {
        geolocation.isMapUIAdmitted && geolocation.isAvailable
    }
    private var isMapVisible: Bool { showingMap && canShowMap }
    var body: some View {
        HSplitView {
            MonitorSidebarView(
                query: $query,
                selectionID: $selectionID,
                hierarchy: hierarchy,
                rows: Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0) }),
                summary: summary,
                controlPlane: session.controlPlane,
                artworkStore: session.applicationArtwork,
                now: queryNow,
                attentionMessage: monitorAttentionMessage(for: session.lifecycle),
                errorMessage: loadError,
                loading: loading,
                hasMore: displayed.count > visibleLimit,
                applyingEventID: applyingEventID,
                availableLenses: availableLenses,
                showFilterStatus: session.requestFilterStatus,
                loadMore: loadMore,
                apply: { apply($0, $1) },
                showRules: showRules
            )
            .frame(
                minWidth: 240,
                idealWidth: isMapVisible ? 313 : 640,
                maxWidth: isMapVisible ? 313 : .infinity
            )
            .layoutPriority(1)

            if isMapVisible {
                MonitorMapSection(
                    rows: mapRows,
                    metadata: geolocation.metadata,
                    isPreview: session.isUIFixture,
                    selectedLocationID: $query.focusedLocationID,
                    origin: $mapOrigin,
                    isPlacingOrigin: $isPlacingOrigin,
                    onMapReady: signalFixtureReadiness
                )
                .ignoresSafeArea(.container, edges: .top)
                .frame(minWidth: 420, idealWidth: 645, maxWidth: .infinity)
            }

            MonitorSummaryView(
                summary: summary,
                selectedNode: selectedNode,
                selectedRow: selectedRow,
                applyingEventID: applyingEventID,
                artworkStore: session.applicationArtwork,
                apply: { apply($0, $1) },
                showRules: { selectedNode.map { showRules($0.ruleCoverage.ruleIDs) } }
            )
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 320)
            .layoutPriority(1)
        }
        .frame(minWidth: 960, minHeight: 560)
        .toolbar {
            MonitorToolbarContent(
                isPreview: session.isUIFixture,
                canShowMap: canShowMap,
                showingMap: showingMap,
                showFilterStatus: session.requestFilterStatus,
                openRules: {
                    openWindow(id: "rules")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                },
                toggleMap: toggleMap,
                refresh: { scheduleReload() }
            )
        }
        .sheet(isPresented: $session.showingFilterStatus) {
            if let lifecycle = session.lifecycle {
                FilterStatusView(
                    controller: lifecycle,
                    controlPlane: session.controlPlane
                )
            }
        }
        .confirmationDialog(
            "Show the destination map?",
            isPresented: $showingMapDisclosure,
            titleVisibility: .visible
        ) {
            Button("Show Map") {
                UserDefaults.standard.set(true, forKey: "monitorMapDisclosureAcknowledged")
                setMapVisible(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MapKit requests tiles for viewed regions. Destination lookup remains local, and Abyss does not send endpoint IPs or app identities to a geolocation service.")
        }
        .modifier(MonitorManagedListOverrideConfirmation(
            pending: $pendingManagedListOverride,
            confirm: { apply(.allow, $0, elevatedOverrideConfirmed: true) }
        ))
        .task { session.controlPlane.monitorDidAppear(); await start() }
        .onChange(of: session.controlPlane.activityRevision) { _, _ in scheduleReload() }
        .onChange(of: query) { _, _ in scheduleQueryUpdate() }
        .onChange(of: selectionID) { _, _ in
            if let eventID = selectedNode?.eventID { selectedEventID = eventID }
        }
        .onChange(of: session.requestedMonitorEventID) { _, _ in
            acceptRequestedSelection()
        }
        .onChange(of: geolocation.metadata) { _, _ in
            Task { await reloadGeography() }
        }
        .onKeyPress(.escape) {
            guard isPlacingOrigin else { return .ignored }
            isPlacingOrigin = false
            return .handled
        }
        .onDisappear { stop(); session.controlPlane.monitorDidDisappear() }
    }
    private var availableLenses: [MonitorLens] {
        MonitorLens.available(
            mapUIAdmitted: geolocation.isMapUIAdmitted,
            geolocationDatabaseAvailable: geolocation.isAvailable
        )
    }

    private func start() async {
        await session.waitForGeolocation()
        guard !Task.isCancelled else { return }
#if DEBUG
        if session.isUIFixture {
            showingMap = true
        } else {
            showingMap = geolocation.isAvailable
                && UserDefaults.standard.bool(forKey: "monitorMapDisclosureAcknowledged")
                && UserDefaults.standard.bool(forKey: "monitorMapVisible")
        }
#else
        showingMap = geolocation.isAvailable
            && UserDefaults.standard.bool(forKey: "monitorMapDisclosureAcknowledged")
            && UserDefaults.standard.bool(forKey: "monitorMapVisible")
#endif
        monitorIsReady = true
        let task = scheduleReload()
        await task?.value
    }
    @discardableResult
    private func scheduleReload() -> Task<Void, Never>? {
        guard monitorIsReady else { return nil }
        let requestID = UUID()
        activeRefreshID = requestID
        let previous = refreshTask
        previous?.cancel()
        queryTask?.cancel()
        activeQueryRequestID = MonitorQueryRequestID()
        let task = Task { @MainActor in
            if let previous { await previous.value }
            await Task.yield()
            guard !Task.isCancelled, requestID == activeRefreshID else { return }
            await reload(requestID: requestID)
        }
        refreshTask = task
        return task
    }
    private func reload(requestID: UUID) async {
        guard !Task.isCancelled, requestID == activeRefreshID else { return }
        loading = true
        defer { if requestID == activeRefreshID { loading = false } }
        do {
#if DEBUG
            let refreshedNow = session.isUIFixture ? queryNow : Date()
#else
            let refreshedNow = Date()
#endif
            let snapshot = try await session.controlPlane.monitorRowsSnapshot()
            let refreshedGeography = try await geolocation.resolutions(for: snapshot.rows)
            queryTask?.cancel()
            let queryRequestID = MonitorQueryRequestID()
            activeQueryRequestID = queryRequestID
            let result = try await MonitorQueryEvaluator.evaluate(
                rows: snapshot.rows, geography: refreshedGeography,
                state: query, now: refreshedNow, queryComplete: snapshot.isComplete,
                coverage: snapshot.coverage
            )
            guard !Task.isCancelled, requestID == activeRefreshID else { return }
            applySourceSnapshot(snapshot, geography: refreshedGeography, now: refreshedNow)
            guard queryMayPublish(queryRequestID) else {
                scheduleQueryUpdate(debounce: false)
                return
            }
            publish(result)
            loadError = nil
            await reloadCoverage(refreshID: requestID, queryRequestID: queryRequestID)
            guard !Task.isCancelled, requestID == activeRefreshID,
                  queryMayPublish(queryRequestID) else { return }
            acceptRequestedSelection()
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, requestID == activeRefreshID else { return }
            loadError = "Couldn’t refresh. Showing saved activity."
        }
    }

    private func stop() {
        refreshTask?.cancel()
        queryTask?.cancel()
    }

    private func reloadGeography() async {
        do {
            geography = try await geolocation.resolutions(for: allRows)
            restoreRememberedMapVisibility()
            let task = scheduleQueryUpdate(debounce: false)
            await task.value
        } catch {
            loadError = "Couldn’t refresh locations. Showing saved activity."
        }
    }

    @discardableResult
    private func scheduleQueryUpdate(debounce: Bool = true) -> Task<Void, Never> {
        queryTask?.cancel()
        let requestID = MonitorQueryRequestID()
        activeQueryRequestID = requestID
        let task = Task {
            if debounce {
                do { try await Task.sleep(for: .milliseconds(160)) }
                catch { return }
            }
            guard queryMayPublish(requestID) else { return }
            await updateQuery(requestID: requestID)
        }
        queryTask = task
        return task
    }

    private func updateQuery(requestID: MonitorQueryRequestID) async {
        let rows = allRows
        let geography = geography
        let state = query
        let now = queryNow
        let complete = rowsAreComplete
        do {
            let result = try await MonitorQueryEvaluator.evaluate(
                rows: rows, geography: geography,
                state: state, now: now, queryComplete: complete,
                coverage: historyCoverage
            )
            guard queryMayPublish(requestID) else { return }
            publish(result)
            await reloadCoverage(queryRequestID: requestID)
            guard queryMayPublish(requestID) else { return }
            acceptRequestedSelection()
        } catch is CancellationError {
        } catch {
            guard queryMayPublish(requestID) else { return }
            loadError = "Couldn’t refresh. Showing saved activity."
        }
    }

    private func reloadCoverage(
        refreshID: UUID? = nil,
        queryRequestID: MonitorQueryRequestID? = nil
    ) async {
        do {
            let refreshed = try await session.controlPlane.monitorRuleCoverage(
                for: visibleRows.map(\.source)
            )
            guard !Task.isCancelled,
                  refreshID == nil || refreshID == activeRefreshID,
                  queryRequestID.map(queryMayPublish) ?? true else { return }
            coverages = refreshed
        } catch {
            guard !Task.isCancelled,
                  refreshID == nil || refreshID == activeRefreshID,
                  queryRequestID.map(queryMayPublish) ?? true else { return }
            loadError = "Couldn’t refresh rule coverage. Showing saved activity."
        }
    }

    private func applySourceSnapshot(
        _ snapshot: MonitorRowsSnapshot,
        geography refreshedGeography: [String: GeoResolution],
        now: Date
    ) {
        queryNow = now
        allRows = snapshot.rows
        rowsAreComplete = snapshot.isComplete
        historyCoverage = snapshot.coverage
        geography = refreshedGeography
    }

    private func publish(_ result: MonitorQueryEvaluation) {
        displayed = result.displayed
        refreshPinnedRow()
        mapRows = result.mapRows
        summary = result.summary
        restoreSelection()
        signalFixtureReadiness()
    }

    private func queryMayPublish(_ requestID: MonitorQueryRequestID) -> Bool {
        MonitorQueryPublication.permits(requestID, active: activeQueryRequestID,
                                        taskIsCancelled: Task.isCancelled)
    }

    private func loadMore() {
        visibleLimit = min(displayed.count, visibleLimit + 1_000)
        Task { await reloadCoverage() }
    }

    private func apply(
        _ action: FilterAction,
        _ node: MonitorHierarchyNode,
        elevatedOverrideConfirmed: Bool = false
    ) {
        guard let eventID = node.ruleSeedEventID,
              let row = allRows.first(where: { $0.id == eventID }) else { return }
        applyingEventID = eventID
        Task {
            do {
                try await session.controlPlane.applyExactMonitorRule(
                    for: row,
                    action: action,
                    elevatedOverrideConfirmed: elevatedOverrideConfirmed
                )
                loadError = nil
                await reloadCoverage()
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                pendingManagedListOverride = node
                loadError = nil
            } catch {
                loadError = "The exact rule wasn’t applied. Retry after Abyss reconnects."
            }
            applyingEventID = nil
        }
    }

    private func showRules(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        session.requestedRuleIDs = ids
        openWindow(id: "rules")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func acceptRequestedSelection() {
        guard let target = session.requestedMonitorEventID else { return }
        if let index = displayed.firstIndex(where: { $0.source.id == target }) {
            pinnedDisplayRow = displayed[index]
            if let node = MonitorHierarchyBuilder.node(forEventID: target, in: hierarchy) {
                selectionID = node.id
                selectedEventID = target
                session.requestedMonitorEventID = nil
                return
            }
        }
        if allRows.contains(where: { $0.id == target }) {
            query.clearExcludingFilters()
        } else if rowsAreComplete
                    && historyCoverage.coverage(for: .all, now: queryNow) == .complete {
            loadError = "That activity is no longer retained or was privacy-hidden."
            session.requestedMonitorEventID = nil
        }
    }

    private func restoreSelection() {
        guard let eventID = selectedEventID,
              let node = MonitorHierarchyBuilder.node(forEventID: eventID, in: hierarchy) else {
            if selectionID.flatMap({ MonitorHierarchyBuilder.node(withID: $0, in: hierarchy) }) == nil {
                selectionID = nil
            }
            return
        }
        selectionID = node.id
    }

    private func refreshPinnedRow() {
        guard let id = pinnedDisplayRow?.id else { return }
        pinnedDisplayRow = displayed.first { $0.id == id }
    }

    private func toggleMap() {
        if showingMap {
            setMapVisible(false)
            return
        }
#if DEBUG
        if session.isUIFixture {
            showingMap = true
            return
        }
#endif
        if UserDefaults.standard.bool(forKey: "monitorMapDisclosureAcknowledged") {
            setMapVisible(true)
        } else {
            showingMapDisclosure = true
        }
    }

    private func setMapVisible(_ visible: Bool) {
        let willShow = visible && canShowMap
        showingMap = willShow
#if DEBUG
        if !session.isUIFixture {
            UserDefaults.standard.set(willShow, forKey: "monitorMapVisible")
        }
#else
        UserDefaults.standard.set(willShow, forKey: "monitorMapVisible")
#endif
        if !willShow {
            if query.focusedLocationID != nil { query.focusedLocationID = nil }
            if isPlacingOrigin { isPlacingOrigin = false }
        }
    }

    private func restoreRememberedMapVisibility() {
#if DEBUG
        guard !session.isUIFixture else { return }
#endif
        guard canShowMap,
              UserDefaults.standard.bool(forKey: "monitorMapDisclosureAcknowledged"),
              UserDefaults.standard.bool(forKey: "monitorMapVisible") else { return }
        showingMap = true
    }

    private func signalFixtureReadiness() {
#if DEBUG
        guard session.isUIFixture else { return }
        MonitorFixtureData.signalVisualReadiness()
#endif
    }
}
