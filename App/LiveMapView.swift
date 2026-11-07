import RiftControl
import RiftCore
import SwiftUI

/// The Map page: the map fills the window, with floating panels for the
/// connection list (which expands into a table), the timeline and the
/// inspector. It replaces both the old Map and Activity pages.
struct LiveMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: AppSession
    @AppStorage("liveMapTrafficChartVisible") private var showingTimeline = true
    @AppStorage("liveMapSummaryVisible") private var showingInspector = true
    @AppStorage("liveMapStyle") private var mapStyle = NetworkMapStyle.standard
    @AppStorage("liveMapTimelineMode") private var timelineMode = RiftTimelineMode.traffic
    @State private var feed: MonitorFeed
    @State private var originController: MapOriginController
    @State private var tableExpanded = false
    @State private var showingMapInformation = false
    @State private var mapFitRequest = 0
    @State private var timelineHeight: CGFloat = 96
    @FocusState private var searchFocused: Bool

    private let edge = RiftDesign.Panel.edge

    init(session: AppSession) {
        self.session = session
        _feed = State(initialValue: MonitorFeed(session: session))
        _originController = State(initialValue: MapOriginController(persists: !session.isUIFixture))
    }

    var body: some View {
        ZStack {
            LiveMapCanvas(
                displayed: feed.displayed,
                originController: originController,
                selectedEventIDs: Set(feed.selectedNode?.eventIDs ?? []),
                windowIsVisible: feed.windowIsVisible,
                isPreview: session.isUIFixture,
                promptsForLocation: session.protectionStatus.canShowActivity,
                loadError: feed.loadError,
                style: mapStyle,
                fitRequest: mapFitRequest,
                chromeInsets: chromeInsets,
                onReady: signalFixtureReadiness
            )
            if tableExpanded {
                Rectangle()
                    .fill(.black.opacity(0.16))
                    .ignoresSafeArea()
                    .onTapGesture { collapseTable() }
                    .accessibilityHidden(true)
            }
            panelLayer
        }
        .overlay(alignment: .top) { attentionBanner }
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
        .animation(reduceMotion ? nil : .smooth(duration: RiftDesign.Motion.panel), value: tableExpanded)
        .animation(reduceMotion ? nil : .smooth(duration: RiftDesign.Motion.panel), value: showingInspector)
        .animation(reduceMotion ? nil : .smooth(duration: RiftDesign.Motion.panel), value: showingTimeline)
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task { start() }
        .modifier(ActivityRefreshSignal(controller: session.controlPlane, changed: { feed.scheduleReload() }))
        .onChange(of: session.controlPlane.persistentHistoryEnabled) { _, _ in feed.historyPreferenceChanged() }
        .background(ActivityWindowVisibility(changed: visibilityChanged))
        .onChange(of: session.requestedMonitorEventID, initial: true) { _, id in
            guard id != nil else { return }
            tableExpanded = true
            feed.acceptRequestedSelection()
        }
        .onChange(of: session.showsConnectionTable, initial: true) { _, show in
            guard show else { return }
            tableExpanded = true
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

    // MARK: Panels

    /// Glass panels share one rendering pass in a container instead of each
    /// keeping its own copy of the map behind it.
    @ViewBuilder
    private var panelLayer: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: edge) { panels }
        } else {
            panels
        }
    }

    private var panels: some View {
        VStack(spacing: edge) {
            HStack(alignment: .top, spacing: edge) {
                ConnectionsPanel(
                    feed: feed,
                    artworkStore: session.applicationArtwork,
                    expanded: tableExpanded,
                    toggleExpanded: { tableExpanded ? collapseTable() : (tableExpanded = true) },
                    searchFocus: $searchFocused
                )
                .frame(width: tableExpanded ? nil : RiftDesign.Panel.connections)
                .frame(maxWidth: tableExpanded ? .infinity : nil, maxHeight: .infinity)
                .riftPanel()
                if !tableExpanded { Spacer(minLength: 0) }
                if showingInspector {
                    inspector
                        .frame(width: RiftDesign.Panel.inspector)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
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
                .riftPanel()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timelineHeight = $0 }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(edge)
    }

    private var inspector: some View {
        MonitorSummaryView(
            summary: feed.summary,
            selectedNode: feed.selectedNode,
            selectedRow: feed.selectedRow,
            applyingEventID: feed.applyingEventID,
            artworkStore: session.applicationArtwork,
            apply: { feed.requestRule($0, for: $1) },
            showRules: { feed.selectedNode.map { feed.showRules(for: $0) } },
            canDecide: feed.selectedNode.map(feed.canDecide) ?? false,
            isMinimal: feed.isMinimal
        )
        .riftPanel()
        .overlay(alignment: .topTrailing) {
            Button { showingInspector = false } label: {
                Label("Hide Inspector", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(RiftDesign.Spacing.m)
            .help("Hide the inspector")
        }
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
            .padding(.top, edge)
            .transition(RiftDesign.Motion.slide(fromY: -RiftDesign.Motion.travel, reduceMotion: reduceMotion))
        }
    }

    private func perform(_ action: ProtectionStatus.Action) {
        switch action {
        case .openSystemSettings: session.lifecycle?.openSystemSettings()
        case .resumeRules: session.resumeRules()
        case .setUp, .showStatus, .reviewWaiting: session.destination = .health
        }
    }

    /// The parts of the map covered by panels, so the map keeps its messages,
    /// attribution and fitted routes in the open area.
    private var chromeInsets: EdgeInsets {
        guard !tableExpanded else { return EdgeInsets() }
        return EdgeInsets(
            top: 0,
            leading: RiftDesign.Panel.connections + edge * 2,
            bottom: showingTimeline ? timelineHeight + edge * 2 : 0,
            trailing: showingInspector ? RiftDesign.Panel.inspector + edge * 2 : 0
        )
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
            .keyboardShortcut("i", modifiers: [.command, .option])
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

    private func collapseTable() {
        tableExpanded = false
    }

    private func escape() {
        if originController.isPlacingManually {
            originController.cancelPlacement()
        } else if feed.selectionID != nil {
            feed.selectionID = nil
        } else if tableExpanded {
            collapseTable()
        }
    }

    private func signalFixtureReadiness() {
#if DEBUG
        guard session.isUIFixture else { return }
        MonitorFixtureData.signalVisualReadiness()
#endif
    }
}
