import SwiftUI
import WandererCore

struct TripsView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    @State private var showImport = false
    @State private var showSettings = false
    @State private var newTripName = ""
    @State private var showNewTrip = false

    var body: some View {
        let trips = model.trips()
        List {
            if trips.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(trips) { trip in
                NavigationLink(value: Route.trip(trip.id)) {
                    TripRow(trip: trip)
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { trips[$0].id }
                model.perform { store in try ids.forEach(store.deleteTrip) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Wanderer")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Import itinerary…") { showImport = true }
                    Button("New empty trip…") { newTripName = ""; showNewTrip = true }
                    Button("Add Milan sample") {
                        if let trip = model.loadSample() { path.append(Route.trip(trip.id)) }
                    }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportView { trip in path.append(Route.trip(trip.id)) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("New trip", isPresented: $showNewTrip) {
            TextField("Name", text: $newTripName)
            Button("Create") {
                let name = newTripName.trimmingCharacters(in: .whitespaces)
                let trip = Trip(name: name.isEmpty ? "New trip" : name)
                model.perform { store in
                    try store.save(trip)
                    try store.addDay(tripId: trip.id, name: "Day 1")
                }
                path.append(Route.trip(trip.id))
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plan a day, then go and walk it.")
                .font(.system(.title2, design: .serif))
            Text("Paste an itinerary from ChatGPT or any other assistant, or start from the Milan sample.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button { showImport = true } label: { Text("Import itinerary").primaryButton() }
                Button {
                    if let trip = model.loadSample() { path.append(Route.trip(trip.id)) }
                } label: { Text("Use the Milan sample").secondaryButton() }
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.vertical, 32)
    }
}

private struct TripRow: View {
    @Environment(AppModel.self) private var model
    let trip: Trip

    var body: some View {
        let days = model.days(trip.id)
        let dates = days.compactMap(\.date).sorted()
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.name)
                .font(.system(.title3, design: .serif))
            HStack(spacing: 6) {
                Text(days.count == 1 ? "1 day" : "\(days.count) days")
                if let first = dates.first.flatMap(DayFormat.parse) {
                    Text("·")
                    Text(first.formatted(.dateTime.day().month(.abbreviated)))
                }
                if model.live.map({ live in days.contains { $0.id == live.session.dayId } }) == true {
                    Text("·")
                    Text("Exploring").foregroundStyle(Color.signal)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
