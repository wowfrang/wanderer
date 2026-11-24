import SwiftUI
import MapKit
import CoreLocation
import WandererCore

/// The plan for one day: the map is the interface, the itinerary lives in the panel.
struct DayPlanView: View {
    @Environment(AppModel.self) private var model
    let dayId: String

    @State private var position: MapCameraPosition = .automatic
    @State private var selected: String?
    @State private var expanded = true
    @State private var legs: [RouteLeg] = []
    @State private var panelHeight: CGFloat = 0
    @State private var showSearch = false
    @State private var editingPlace: Place?
    @State private var droppedPin: Coordinate?
    @State private var pinName = ""
    @State private var showPinAlert = false
    @State private var errorMessage: String?
    @State private var editingDay: Day?
    @State private var fittedKey = ""

    private var day: Day? { _ = model.revision; return try? model.store.day(id: dayId) }

    var body: some View {
        let places = model.places(dayId)
        let located = places.filter { $0.coordinate != nil }
        let coordsKey = located.map { $0.coordinate!.cacheKey }.joined(separator: "|")
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                map(places: places, located: located)
                BottomPanel(expanded: $expanded, expandedHeight: geo.size.height * 0.42) {
                    header(places: places, located: located)
                } content: {
                    placeList(places)
                }
                .readHeight($panelHeight)
            }
        }
        .ignoresSafeArea(.keyboard)
        .navigationTitle(day?.name ?? "Day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.regularMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add place…") { showSearch = true }
                    Button("Optimise walking order") { optimise(places) }
                        .disabled(located.count < 4)
                    Button("Edit day…") { editingDay = day }
                    Button("Fit map") { fit(located) }
                    Button(model.settings.satellite ? "Standard map" : "Satellite map") { model.settings.satellite.toggle() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: coordsKey) {
            if fittedKey != coordsKey {
                fit(located)
                fittedKey = coordsKey
            }
            legs = await model.routes.legs(for: located.compactMap(\.coordinate))
            model.changed() // routed distances are now cached; refresh day summaries
        }
        .sheet(isPresented: $showSearch) {
            PlaceSearchView(near: located.last?.coordinate ?? located.first?.coordinate) { result in
                model.perform { store in
                    try store.addPlace(Place(dayId: dayId, name: result.name, address: result.address,
                                             coordinate: result.coordinate, category: result.category))
                }
            }
        }
        .sheet(item: $editingPlace) { place in
            PlaceEditView(place: place)
        }
        .sheet(item: $editingDay) { day in DayEditor(day: day) }
        .alert("Add place here", isPresented: $showPinAlert) {
            TextField("Name", text: $pinName)
            Button("Add") {
                guard let pin = droppedPin else { return }
                let name = pinName.trimmingCharacters(in: .whitespaces)
                model.perform { store in
                    try store.addPlace(Place(dayId: dayId, name: name.isEmpty ? "Dropped pin" : name, coordinate: pin))
                }
                droppedPin = nil
            }
            Button("Cancel", role: .cancel) { droppedPin = nil }
        }
        .alert("Can't start", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Map

    private func map(places: [Place], located: [Place]) -> some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                    MapPolyline(coordinates: leg.points.map(\.cl))
                        .stroke(MapLayer.plannedRoute(satellite: model.settings.satellite), style: leg.isWalkingRoute
                                ? StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                                : StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 7]))
                }
                ForEach(located) { place in
                    Annotation(place.name, coordinate: place.coordinate!.cl, anchor: .center) {
                        MarkerView(number: number(of: place, in: places), selected: selected == place.id)
                            .onTapGesture { select(place, scrollMap: false) }
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(droppedPin.map { [$0] } ?? [], id: \.self) { pin in
                    Marker("New place", coordinate: pin.cl).tint(Color.signal)
                }
            }
            .mapStyle(model.settings.satellite
                      ? .hybrid(elevation: .flat, pointsOfInterest: .including([.museum, .park, .publicTransport]))
                      : .standard(emphasis: .muted, pointsOfInterest: .including([.museum, .park, .publicTransport, .cafe, .restaurant])))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .safeAreaPadding(.bottom, panelHeight)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value,
                              let c = proxy.convert(drag.location, from: .local) else { return }
                        dropPin(Coordinate(c))
                    }
            )
        }
    }

    private func number(of place: Place, in places: [Place]) -> Int {
        (places.firstIndex { $0.id == place.id } ?? 0) + 1
    }

    // MARK: Panel

    private func header(places: [Place], located: [Place]) -> some View {
        let routed = legs.count == max(0, located.count - 1) && !legs.isEmpty
        let distance = routed ? legs.reduce(0) { $0 + $1.distance } : model.plannedDistance(places).metres
        let walking = distance / model.settings.walkingSpeed
        let visiting = places.compactMap(\.visitMinutes).reduce(0, +)
        let liveHere = model.live?.session.dayId == dayId
        let liveElsewhere = model.live != nil && !liveHere

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let d = day, let title = DayFormat.title(d) { Eyebrow(title) }
                HStack(spacing: 6) {
                    Text(places.count == 1 ? "1 place" : "\(places.count) places")
                    if distance > 0 {
                        Text("·")
                        Text(Format.distance(distance))
                        Text("·")
                        Text("\(Format.duration(walking)) walking")
                    }
                    if visiting > 0 {
                        Text("·")
                        Text("\(Format.duration(Double(visiting) * 60)) visiting")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if liveHere {
                Button { model.liveMinimized = false } label: { Text("Return to exploration").primaryButton() }
                    .buttonStyle(.plain)
            } else {
                Button { start() } label: { Text("Start day").primaryButton() }
                    .buttonStyle(.plain)
                    .disabled(located.isEmpty || liveElsewhere)
                    .opacity(located.isEmpty || liveElsewhere ? 0.4 : 1)
                if liveElsewhere {
                    Text("Another day is being explored. Finish it first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func placeList(_ places: [Place]) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    PlaceRow(number: index + 1, place: place, selected: selected == place.id,
                             legAfter: legAfter(place, in: places))
                        .id(place.id)
                        .contentShape(Rectangle())
                        .onTapGesture { select(place, scrollMap: true) }
                        .contextMenu { contextMenu(for: place) }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.perform { try $0.deletePlace(place.id) } }
                            Button("Edit") { editingPlace = place }
                        }
                        .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    var ids = places.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    model.perform { try $0.reorderPlaces(dayId: dayId, orderedIds: ids) }
                }
                Button { showSearch = true } label: {
                    Label("Add place", systemImage: "plus")
                }
                .listRowBackground(Color.clear)
                Text("Long-press the map to drop a pin. Drag rows to reorder.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for place: Place) -> some View {
        Button("Edit…") { editingPlace = place }
        if let days = day.map({ model.days($0.tripId) }), days.count > 1 {
            Menu("Move to day") {
                ForEach(days.filter { $0.id != dayId }) { other in
                    Button(other.name) { model.perform { try $0.movePlace(place.id, toDay: other.id) } }
                }
            }
        }
        if place.coordinate != nil {
            Button("Directions in \(model.settings.mapsApp.title)") { ExternalMaps.openDirections(to: place, using: model.settings.mapsApp) }
        }
        Button("Delete", role: .destructive) { model.perform { try $0.deletePlace(place.id) } }
    }

    private func legAfter(_ place: Place, in places: [Place]) -> RouteLeg? {
        guard let c = place.coordinate else { return nil }
        return legs.first { $0.from == c }
    }

    // MARK: Actions

    private func select(_ place: Place, scrollMap: Bool) {
        selected = place.id
        if scrollMap, let c = place.coordinate {
            withAnimation(.snappy) {
                position = .camera(MapCamera(centerCoordinate: c.cl, distance: 1200))
            }
        }
    }

    private func fit(_ located: [Place]) {
        if let p = MapFit.position(located.compactMap(\.coordinate)) {
            withAnimation(.snappy) { position = p }
        }
    }

    private func optimise(_ places: [Place]) {
        let located = places.filter { $0.coordinate != nil }
        let order = RouteOptimizer.optimizedOrder(located.map { $0.coordinate! })
        let ids = order.map { located[$0].id } + places.filter { $0.coordinate == nil }.map(\.id)
        model.perform { try $0.reorderPlaces(dayId: dayId, orderedIds: ids) }
    }

    private func dropPin(_ c: Coordinate) {
        droppedPin = c
        pinName = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showPinAlert = true
        Task {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first
            if pinName.isEmpty, let name = placemark?.name { pinName = name }
        }
    }

    private func start() {
        do {
            try model.startSession(dayId: dayId)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PlaceRow: View {
    let number: Int
    let place: Place
    var selected = false
    var legAfter: RouteLeg?
    var state: MarkerState = .planned

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MarkerView(number: number, state: state)
                .scaleEffect(0.9)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(state == .visited || state == .skipped ? .secondary : .primary)
                    .strikethrough(state == .skipped, color: .secondary)
                if let subtitle = place.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let notes = place.notes ?? place.details {
                    Text(notes).font(.footnote).foregroundStyle(.tertiary).lineLimit(2)
                }
                if let leg = legAfter {
                    Text("then \(Format.distance(leg.distance)) · \(Format.duration(leg.expectedTravelTime))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
