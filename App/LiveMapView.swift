import RiftControl
import RiftCore
import SwiftUI

/// The Map page: the map above a docked timeline and table of connections,
/// with details in the inspector. It replaces the old Map and Activity pages.
struct LiveMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: AppSession
    @AppStorage("liveMapTrafficChartVisible") private var showingTimeline = true
    @AppStorage("liveMapSummaryVisible") private var showingInspector = true
    @AppStorage("liveMapStyle") private var mapStyle = NetworkMapStyle.standard
    @AppStorage("liveMapTimelineMode") private var timelineMode = RiftTimelineMode.traffic
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
        .inspector(isPresented: $showingInspector) {
            inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .searchable(text: $feed.query.search, placement: .toolbar, prompt: "Search apps and destinations")
        .searchFocused($searchFocused)
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
        .onChange(of: session.controlPlane.ruleChanges.revision) { _, _ in
            feed.requestPresentationRefresh()
        }
#if DEBUG
        .task {
            if let country = FixturePreviewOptions.sampleCountry { feed.query.country = country }
            if ProcessInfo.processInfo.arguments.contains("--ui-fixture-past") {
                feed.query.navigateTime(.previous, now: feed.now)
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
        .onChange(of: feed.selectionID) { _, id in if id != nil { showingInspector = true } }
        .onChange(of: timelineMode, initial: true) { _, mode in feed.wantsDecisionBuckets = mode == .decisions }
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
                toggleMap: { mapHidden.toggle() }
            )
        }
    }

    private var inspector: some View {
        MonitorSummaryView(
            summary: feed.inspectorSummary,
            selectedNode: feed.selectedNode,
            selectedRow: feed.selectedRow,
            applyingEventID: feed.applyingEventID,
            artworkStore: session.applicationArtwork,
            apply: { feed.requestRule($0, for: $1) },
            showRules: { feed.selectedNode.map { feed.showRules(for: $0) } },
            canDecide: feed.selectedNode.map(feed.canDecide) ?? false,
            isMinimal: feed.isMinimal
        )
    }

    @ViewBuilder
    private var attentionBanner: some View {
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
            inspectorShown: showingInspector,
            timelineShown: showingTimeline,
            toggleMap: { mapHidden.toggle() },
            toggleInspector: { showingInspector.toggle() },
            toggleTimeline: { showingTimeline.toggle() },
            find: { searchFocused = true },
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
                Label("Map Options", systemImage: mapStyle == .satellite ? "globe.americas.fill" : "map")
            }
            .help("Map style and options")
            .popover(isPresented: $showingMapInformation) { LiveMapInformation() }
            LiveMapOriginControl(
                hasOrigin: originController.origin != nil,
                beginPlacement: originController.beginManualPlacement,
                clearOrigin: originController.clearOrigin
            )
            Button { showingTimeline.toggle() } label: {
                Label(showingTimeline ? "Hide Timeline" : "Show Timeline", systemImage: "chart.bar.xaxis")
            }
            .help(showingTimeline ? "Hide the timeline" : "Show the timeline")
            Button { showingInspector.toggle() } label: {
                Label(showingInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .help(showingInspector ? "Hide the inspector" : "Show the inspector")
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
