import SwiftUI
import MapKit
import WandererCore

/// The live exploration screen. Designed to be glanced at: pull the phone out of a pocket
/// and see, in one look, where you've been, where you're going and how far it is.
struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let live: LiveSession

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var expanded = false
    @State private var panelHeight: CGFloat = 0
    @State private var confirmFinish = false
    @State private var showSummary = false
    @State private var showSearch = false
    @State private var actionPlace: Place?
    @State private var bannerTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                map
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    topBar
                    banners
                    Spacer()
                }
                .padding(.horizontal, 12)
                VStack {
                    Spacer()
                    BottomPanel(expanded: $expanded, expandedHeight: geo.size.height * 0.45) {
                        header
                    } content: {
                        placeList
                    }
                    .readHeight($panelHeight)
                }
            }
        }
        .sensoryFeedback(.success, trigger: live.visitedCount)
        .confirmationDialog("Finish this day?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish and see summary") {
                Task {
                    await live.finish()
                    showSummary = true
                }
            }
            Button("Keep exploring", role: .cancel) {}
        } message: {
            Text("Tracking stops. You can't resume a finished day, but you can start it again.")
        }
        .sheet(isPresented: $showSearch) {
            PlaceSearchView(near: live.currentLocation.map { Coordinate($0.coordinate) } ?? live.nextPlace?.coordinate) { r in
                live.addSpontaneous(name: r.name, address: r.address, coordinate: r.coordinate, category: r.category)
            }
        }
        .fullScreenCover(isPresented: $showSummary, onDismiss: { model.endLiveSession() }) {
            NavigationStack {
                SummaryView(sessionId: live.session.id)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSummary = false }
                        }
                    }
            }
            .environment(model)
        }
        .confirmationDialog(actionPlace?.name ?? "", isPresented: Binding(get: { actionPlace != nil }, set: { if !$0 { actionPlace = nil } }), titleVisibility: .visible) {
            if let place = actionPlace { actions(for: place) }
        }
        .onAppear {
            if live.isFinished { showSummary = true }
        }
        .onChange(of: live.lastAutoVisit) { _, visit in
            bannerTask?.cancel()
            guard visit != nil else { return }
            bannerTask = Task {
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { live.dismissAutoVisitBanner() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the pocket: show the whole picture, not just the blue dot.
            if phase == .active { overview() }
        }
    }

    // MARK: Map

    private var map: some View {
        let places = live.places
        return Map(position: $position) {
            // Remaining plan: quiet, dashed.
            ForEach(Array(live.remainingLegs.enumerated()), id: \.offset) { _, leg in
                MapPolyline(coordinates: leg.points.map(\.cl))
                    .stroke(Color.plannedRoute.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [2, 7]))
            }
            // You → next stop.
            ForEach(live.legToNext.map { [$0] } ?? [], id: \.self) { leg in
                MapPolyline(coordinates: leg.points.map(\.cl))
                    .stroke(Color.signal.opacity(0.55), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [1, 8]))
            }
            // Where you've actually been: solid and confident.
            // Gaps while GPS was off (phone in pocket): a faint dotted link, not a claim.
            ForEach(Array(PathGaps.connectors(live.path).enumerated()), id: \.offset) { _, gap in
                MapPolyline(coordinates: gap.map(\.cl))
                    .stroke(Color.signal.opacity(0.45), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.5, 7]))
            }
            ForEach(Array(live.path.filter { $0.count > 1 }.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.map(\.cl))
                    .stroke(Color.signal, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(places.filter { $0.coordinate != nil }) { place in
                Annotation(place.name, coordinate: place.coordinate!.cl, anchor: .center) {
                    MarkerView(number: number(place), state: markerState(place))
                        .onTapGesture { actionPlace = place }
                }
                .annotationTitles(live.nextPlaceId == place.id ? .visible : .hidden)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .safeAreaPadding(.bottom, panelHeight)
        .safeAreaPadding(.top, 60)
    }

    private func number(_ place: Place) -> Int {
        (live.places.firstIndex { $0.id == place.id } ?? 0) + 1
    }

    private func markerState(_ place: Place) -> MarkerState {
        switch live.status(place) {
        case .visited: return .visited
        case .skipped: return .skipped
        case .pending: return live.nextPlaceId == place.id ? .next : .planned
        }
    }

    private func overview() {
        var coords = live.path.flatMap { $0 }
        if let next = live.nextPlace?.coordinate { coords.append(next) }
        if let here = live.currentLocation { coords.append(Coordinate(here.coordinate)) }
        if coords.count < 2 { coords += live.places.compactMap(\.coordinate) }
        if let p = MapFit.position(coords, minimumSpan: 0.004) {
            withAnimation(.snappy) { position = p }
        }
    }

    // MARK: Overlays

    private var topBar: some View {
        HStack {
            CircleButton(systemName: "chevron.down", label: "Minimise") { model.liveMinimized = true }
            Spacer()
            if live.isPaused {
                Text("Paused")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            Spacer()
            HStack(spacing: 8) {
                CircleButton(systemName: "square.dashed", label: "Show overview") { overview() }
                CircleButton(systemName: "location", label: "Follow me") {
                    withAnimation { position = .userLocation(fallback: .automatic) }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var banners: some View {
        if live.locationDenied {
            Banner(text: "Location is off for Wanderer, so nothing is being tracked.", action: "Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        } else if live.reducedAccuracy {
            Banner(text: "Precise location is off. Distances and visits will be unreliable.", action: "Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        if live.lastAutoVisit == nil, let here = live.nearbyPendingPlace {
            Banner(text: "You're at \(here.name)", action: "Visited") { live.mark(here, .visited) }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let visit = live.lastAutoVisit {
            Banner(text: "Visited \(visit.placeName)", action: "Undo") { live.undoLastAutoVisit() }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Panel

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            nextStop
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .top, spacing: 8) {
                    Stat(label: "Walked", value: Format.distance(live.walkedDistance))
                    Stat(label: "Time", value: Format.clock(live.elapsed(at: context.date)))
                    Stat(label: "Steps", value: live.steps.map { $0.formatted() } ?? "–")
                    Stat(label: "Places", value: "\(live.visitedCount)/\(live.places.count)")
                }
            }
            controls
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var nextStop: some View {
        if let next = live.nextPlace {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(live.session.targetPlaceId == next.id ? "Heading to" : "Next")
                    Text(next.name)
                        .font(.system(.title2, design: .serif))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if let d = live.distanceToNext, let t = live.timeToNext {
                        Text("\(Format.distance(d)) · \(Format.duration(t))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    } else {
                        Text("Waiting for location…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    ExternalMaps.openDirections(to: next, using: model.settings.mapsApp)
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(Color(UIColor.secondarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Directions in \(model.settings.mapsApp.title)")
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow("Done")
                Text(live.places.isEmpty ? "No places planned" : "Every place is visited or skipped")
                    .font(.system(.title3, design: .serif))
                Text("Keep wandering, add a place, or finish the day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if live.isPaused {
                Button { live.resume() } label: { Text("Resume").primaryButton() }
            } else {
                Button { live.pause() } label: { Text("Pause").secondaryButton() }
            }
            if let next = live.nextPlace {
                Button { live.mark(next, .visited) } label: { Text("I'm here").secondaryButton() }
            }
            Button { confirmFinish = true } label: {
                if live.nextPlace == nil { Text("Finish").primaryButton() } else { Text("Finish").secondaryButton() }
            }
        }
        .buttonStyle(.plain)
    }

    private var placeList: some View {
        List {
            ForEach(Array(live.places.enumerated()), id: \.element.id) { index, place in
                PlaceRow(number: index + 1, place: place, selected: live.nextPlaceId == place.id,
                         state: markerState(place))
                    .contentShape(Rectangle())
                    .onTapGesture { actionPlace = place }
                    .swipeActions(edge: .leading) {
                        if live.status(place) == .pending {
                            Button("Visited") { live.mark(place, .visited) }.tint(.green)
                        } else {
                            Button("Undo") { live.mark(place, .reset) }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if live.status(place) == .pending {
                            Button("Skip") { live.mark(place, .skipped) }.tint(.gray)
                        }
                    }
                    .listRowBackground(Color.clear)
            }
            .onMove { from, to in
                var ids = live.places.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                live.reorder(ids)
            }
            Button { showSearch = true } label: { Label("Add a place", systemImage: "plus") }
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func actions(for place: Place) -> some View {
        let status = live.status(place)
        if status == .pending, live.nextPlaceId != place.id, place.coordinate != nil {
            Button("Go here next") { live.goNext(place) }
        }
        if status != .visited { Button("Mark as visited") { live.mark(place, .visited) } }
        if status == .pending { Button("Skip") { live.mark(place, .skipped) } }
        if status != .pending { Button(status == .visited ? "Not visited yet" : "Unskip") { live.mark(place, .reset) } }
        if place.coordinate != nil {
            Button("Directions in \(model.settings.mapsApp.title)") { ExternalMaps.openDirections(to: place, using: model.settings.mapsApp) }
        }
    }
}

private struct CircleButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct Banner: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.subheadline.weight(.medium)).lineLimit(2)
            Spacer(minLength: 8)
            Button(action, action: perform).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}
