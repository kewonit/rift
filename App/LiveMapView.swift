import RiftControl
import RiftCore
import SwiftUI

/// The Map page: the map above a docked timeline and table of connections,
/// with details in the inspector. It replaces the old Map and Activity pages.
struct LiveMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: AppSession
    @AppStorage("liveMapTrafficChartVisible") private var showingTimeline = true
    @AppStorage("liveMapStyle") private var mapStyle = NetworkMapStyle.standard
    @AppStorage("liveMapTimelineMode") private var timelineMode = RiftTimelineMode.traffic
    /// Keeps the inspector open with a summary when nothing is selected.
    @AppStorage("liveMapSummaryShown") private var summaryShown = false
    @State private var feed: MonitorFeed
    @State private var originController: MapOriginController
    @State private var mapHidden = false
    @State private var showingMapInformation = false
    @State private var mapFitRequest = 0
    @FocusState private var searchFocused: Bool


    init(session: AppSession) {
        self.session = session
        _feed = State(initialValue: MonitorFeed(session: session))
        _originController = State(initialValue: MapOriginController(persists: !session.isUIFixture))
    }

    var body: some View {
        RiftVerticalSplit(topHidden: mapHidden, minTop: 220, minBottom: 240) {
            map
        } bottom: {
            connections
        }
        .inspector(isPresented: inspectorShown) {
            inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .navigationTitle("Map")
        .focusedSceneValue(\.mapCommands, mapCommands)
        .sheet(item: $feed.pendingRuleRequest) { request in
            RuleScopeChooser(request: request) { breadth, duration in
                feed.pendingRuleRequest = nil
                feed.applyRule(request, breadth: breadth, duration: duration)
            } cancel: {
                feed.pendingRuleRequest = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { session.review.isPresented }, set: { session.review.isPresented = $0 }
        )) {
            ReviewView(
                model: session.review,
                mode: session.controlPlane.currentMode,
                keepsHistory: session.controlPlane.persistentHistoryEnabled,
                artworkStore: session.applicationArtwork,
                showOnMap: { app in
                    session.review.isPresented = false
                    let name = MonitorQuery.identityLabel(app.identity).replacingOccurrences(of: "\"", with: "")
                    feed.query.search = "app:\"\(name)\""
                    feed.query.decision = .unresolved
                },
                switchToAskMe: {
                    session.review.isPresented = false
                    Task { _ = try? await session.controlPlane.setEffectiveMode(.alert) }
                }
            )
        }
        .onChange(of: session.controlPlane.ruleChanges.revision) { _, _ in
            feed.requestPresentationRefresh()
        }
#if DEBUG
        .task {
            if let country = FixturePreviewOptions.sampleCountry { feed.query.country = country }
            if ProcessInfo.processInfo.arguments.contains("--ui-fixture-past") {
                feed.query.navigateTime(.previous, now: feed.now)
            }
            if FixturePreviewOptions.selectsConnection {
                try? await Task.sleep(for: .seconds(1))
                feed.selectionID = feed.hierarchy.dropFirst().first?.id
            }
            guard let step = FixturePreviewOptions.sampleRuleAction else { return }
            try? await Task.sleep(for: .seconds(2))
            guard let node = feed.hierarchy.first(where: {
                $0.ruleSeedEventID != nil && $0.aggregate.denied == 0
            }) else { return }
            feed.selectionID = node.id
            feed.requestRule(.deny, for: node)
            guard step != "chooser" else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if let request = feed.pendingRuleRequest {
                feed.pendingRuleRequest = nil
                feed.applyRule(request, breadth: request.options[0], duration: .always)
            }
            guard step == "undo" else { return }
            try? await Task.sleep(for: .seconds(2))
            _ = try? await session.controlPlane.undoLastRuleChange()
            session.controlPlane.actionResults.post("Undone.", offersUndo: true)
        }
#endif
        .animation(reduceMotion ? nil : RiftDesign.Motion.enter(), value: showingTimeline)
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task { start() }
        .modifier(ActivityRefreshSignal(controller: session.controlPlane, changed: { feed.scheduleReload() }))
        .onChange(of: session.controlPlane.persistentHistoryEnabled) { _, _ in feed.historyPreferenceChanged() }
        .background(ActivityWindowVisibility(changed: visibilityChanged))
        .onChange(of: session.requestedMonitorEventID, initial: true) { _, id in
            guard id != nil else { return }
            feed.acceptRequestedSelection()
        }
        .onChange(of: session.showsConnectionTable, initial: true) { _, show in
            guard show else { return }
            mapHidden = true
            session.showsConnectionTable = false
        }
        .onChange(of: timelineMode, initial: true) { _, mode in feed.wantsDecisionBuckets = mode == .decisions }
        .onChange(of: summaryShown, initial: true) { _, shown in feed.wantsSummary = shown }
        .onExitCommand(perform: escape)
        .onDisappear {
            feed.stop()
            originController.cancelPlacement()
        }
        .modifier(MonitorManagedListOverrideConfirmation(
            pending: $feed.pendingManagedListOverride,
            confirm: feed.confirmManagedListOverride
        ))
    }

    // MARK: Panes

    private var map: some View {
        LiveMapCanvas(
            displayed: feed.mapRows,
            selectedCountry: feed.query.country,
            isViewingPast: feed.query.isViewingPast,
            selectCountry: { feed.query.country = $0 },
            originController: originController,
            selectedEventIDs: Set(feed.selectedNode?.eventIDs ?? []),
            windowIsVisible: feed.windowIsVisible,
            isPreview: session.isUIFixture,
            promptsForLocation: session.protectionStatus.canShowActivity,
            loadError: feed.loadError,
            style: mapStyle,
            fitRequest: mapFitRequest,
            onReady: signalFixtureReadiness
        )
        .overlay(alignment: .top) { attentionBanner }
    }

    private var connections: some View {
        VStack(spacing: 0) {
            if showingTimeline {
                RiftTimeline(
                    mode: $timelineMode,
                    query: $feed.query,
                    traffic: feed.traffic,
                    decisions: feed.decisions,
                    now: feed.now,
                    isMinimal: feed.isMinimal,
                    refreshFailed: feed.loadError != nil
                )
                Divider()
            }
            ConnectionsPanel(
                feed: feed,
                artworkStore: session.applicationArtwork,
                mapHidden: mapHidden,
                toggleMap: { mapHidden.toggle() },
                searchFocus: $searchFocused
            )
        }
    }

    /// The inspector shows the selected connection, or a summary when
    /// nothing is selected and the summary is on.
    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { feed.selectedNode != nil || summaryShown },
            set: { if !$0 { hideInspector() } }
        )
    }

    private func hideInspector() {
        feed.selectionID = nil
        summaryShown = false
    }

    private func toggleInspector() {
        if inspectorShown.wrappedValue { hideInspector() } else { summaryShown = true }
    }

    @ViewBuilder
    private var inspector: some View {
        if let node = feed.selectedNode {
            ConnectionInspectorView(
                node: node,
                row: feed.selectedRow,
                applyingEventID: feed.applyingEventID,
                artworkStore: session.applicationArtwork,
                apply: { feed.requestRule($0, for: node) },
                showRules: { feed.showRules(for: node) },
                ruleSummaries: { await session.controlPlane.ruleSummaries($0) },
                canDecide: feed.canDecide(node)
            )
        } else {
            MonitorSummaryView(
                summary: feed.summary,
                isViewingPast: feed.query.isViewingPast
            )
        }
    }

    private var attentionBanner: some View {
        VStack(spacing: RiftDesign.Spacing.s) {
            statusBanner
            reviewBanner
        }
    }

    /// Offers the Review sheet while something is left to decide.
    @ViewBuilder
    private var reviewBanner: some View {
        let review = session.review
        if review.count > 0, !review.isPresented {
            RiftBanner(message: ReviewBannerCopy.message(review.queue), detail: nil, tone: .info) {
                Button("Review") { review.isPresented = true }
                    .controlSize(.small)
            }
            .frame(maxWidth: 480)
            .riftPanel(cornerRadius: RiftDesign.Radius.card)
            .padding(.top, session.protectionStatus.showsBanner ? 0 : RiftDesign.Spacing.m)
            .transition(RiftDesign.Motion.slide(fromY: -RiftDesign.Motion.travel, reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let status = session.protectionStatus
        if status.showsBanner {
            RiftBanner(
                message: status.title,
                detail: status.detail,
                tone: status.tone == .attention ? .warning : .info
            ) {
                if let action = status.action {
                    Button(action.title) { perform(action) }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: 480)
            .riftPanel(cornerRadius: RiftDesign.Radius.card)
            .padding(.top, RiftDesign.Spacing.m)
            .transition(RiftDesign.Motion.slide(fromY: -RiftDesign.Motion.travel, reduceMotion: reduceMotion))
        }
    }

    private var mapCommands: MapCommandActions {
        let selected = feed.selectedNode
        return MapCommandActions(
            mapHidden: mapHidden,
            inspectorShown: inspectorShown.wrappedValue,
            timelineShown: showingTimeline,
            toggleMap: { mapHidden.toggle() },
            toggleInspector: toggleInspector,
            toggleTimeline: { showingTimeline.toggle() },
            find: { searchFocused = true },
            startFromNow: { feed.query.startFromNow(Date()) },
            decide: selected.flatMap { node in
                feed.canDecide(node) ? { feed.requestRule($0, for: node) } : nil
            },
            showRule: selected.flatMap { node in
                node.ruleCoverage.ruleIDs.isEmpty ? nil : { feed.showRules(for: node) }
            }
        )
    }

    private func perform(_ action: ProtectionStatus.Action) {
        switch action {
        case .openSystemSettings: session.lifecycle?.openSystemSettings()
        case .resumeRules: session.resumeRules()
        case .setUp, .showStatus, .reviewWaiting: session.destination = .health
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Map Style", selection: $mapStyle) {
                    ForEach(NetworkMapStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Show All Routes") {
                    feed.query.country = nil
                    feed.selectionID = nil
                    mapFitRequest &+= 1
                }
                Button("About the Map…") { showingMapInformation = true }
            } label: {
                Label("Map Options", systemImage: "square.2.layers.3d")
            }
            .help("Map style and options")
            .popover(isPresented: $showingMapInformation) { LiveMapInformation() }
            LiveMapOriginControl(
                hasOrigin: originController.origin != nil,
                beginPlacement: originController.beginManualPlacement,
                clearOrigin: originController.clearOrigin
            )
            Button { showingTimeline.toggle() } label: {
                Label(showingTimeline ? "Hide Timeline" : "Show Timeline", systemImage: "chart.bar")
            }
            .help(showingTimeline ? "Hide the timeline" : "Show the timeline")
            Button(action: toggleInspector) {
                Label(inspectorShown.wrappedValue ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .help(inspectorShown.wrappedValue
                ? "Hide the inspector"
                : "Show the inspector, with a summary when no connection is selected")
        }
    }

    // MARK: Lifecycle

    private func start() {
#if DEBUG
        if session.isUIFixture, MonitorFixtureData.scenario != .missingOrigin,
           let coordinate = try? CoarseMapCoordinate(latitude: 37.75, longitude: -122.5) {
            originController.origin = CoarseMapOrigin(coordinate: coordinate)
        }
#endif
        feed.start()
    }

    private func visibilityChanged(_ visible: Bool) {
        feed.visibilityChanged(visible)
        if !visible { originController.cancelPlacement() }
    }

    private func escape() {
        if originController.isPlacingManually {
            originController.cancelPlacement()
        } else if feed.selectionID != nil {
            feed.selectionID = nil
        } else if mapHidden {
            mapHidden = false
        }
    }

    private func signalFixtureReadiness() {
#if DEBUG
        guard session.isUIFixture else { return }
        MonitorFixtureData.signalVisualReadiness()
#endif
    }
}
