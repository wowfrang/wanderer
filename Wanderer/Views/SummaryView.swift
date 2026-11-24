import SwiftUI
import MapKit
import WandererCore

/// What actually happened on a day: route walked, places visited and skipped, numbers.
struct SummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    @State private var confirmDelete = false

    var body: some View {
        let engine = loadEngine()
        ScrollView {
            if let engine {
                content(engine)
            } else {
                Text("This walk no longer exists.").foregroundStyle(.secondary).padding(40)
            }
        }
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete this walk", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Delete this walk?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.perform { try $0.deleteSession(sessionId) }
                dismiss()
            }
        }
    }

    private func loadEngine() -> SessionEngine? {
        _ = model.revision
        return try? SessionEngine.restore(sessionId: sessionId, store: model.store)
    }

    @ViewBuilder
    private func content(_ engine: SessionEngine) -> some View {
        let session = engine.session
        let day = try? model.store.day(id: session.dayId)
        let statuses = engine.statuses
        let visitedEvents = latestVisits(engine.events, statuses: statuses)
        let skipped = engine.places.filter { statuses[$0.id] == .skipped }
        let notReached = engine.places.filter { (statuses[$0.id] ?? .pending) == .pending }

        VStack(alignment: .leading, spacing: 24) {
            SummaryMap(engine: engine)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(session.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                Text(day?.name ?? "Walk").font(.system(.largeTitle, design: .serif))
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    Stat(label: "Distance", value: Format.distance(session.distance))
                    Stat(label: "Time", value: Format.clock(engine.elapsed()))
                }
                GridRow {
                    Stat(label: "Steps", value: session.steps.map { $0.formatted() } ?? "–")
                    Stat(label: "Places", value: "\(visitedEvents.count) of \(engine.places.count)")
                }
                GridRow {
                    Stat(label: "Started", value: session.startedAt.formatted(date: .omitted, time: .shortened))
                    Stat(label: "Finished", value: session.endedAt?.formatted(date: .omitted, time: .shortened) ?? "–")
                }
            }
            if session.steps == nil {
                Text("Steps weren't available (Motion & Fitness permission is off, or this device has no step counter).")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if !visitedEvents.isEmpty {
                section("Visited") {
                    ForEach(visitedEvents) { e in
                        HStack {
                            Text(e.placeName)
                            Spacer()
                            Text(e.timestamp.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            if !skipped.isEmpty {
                section("Skipped") { ForEach(skipped) { Text($0.name).foregroundStyle(.secondary) } }
            }
            if !notReached.isEmpty {
                section("Not reached") { ForEach(notReached) { Text($0.name).foregroundStyle(.secondary) } }
            }
        }
        .padding(20)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One visit per place (the most recent one that still stands), in the order they happened.
    private func latestVisits(_ events: [VisitEvent], statuses: [String: PlaceStatus]) -> [VisitEvent] {
        var seen = Set<String>()
        var result: [VisitEvent] = []
        for e in events.reversed() where e.kind == .visited {
            guard let id = e.placeId, statuses[id] == .visited, !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(e)
        }
        return result.reversed()
    }
}

private struct SummaryMap: View {
    let engine: SessionEngine
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        let statuses = engine.statuses
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(Array(engine.path.filter { $0.count > 1 }.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.map(\.cl))
                    .stroke(Color.signal, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(engine.places.enumerated()).filter { $0.element.coordinate != nil }, id: \.element.id) { index, place in
                Annotation(place.name, coordinate: place.coordinate!.cl, anchor: .center) {
                    MarkerView(number: index + 1, state: {
                        switch statuses[place.id] ?? .pending {
                        case .visited: return .visited
                        case .skipped: return .skipped
                        case .pending: return .planned
                        }
                    }())
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .onAppear {
            var coords = engine.path.flatMap { $0 }
            if coords.count < 2 { coords += engine.places.compactMap(\.coordinate) }
            if let p = MapFit.position(coords) { position = p }
        }
    }
}
