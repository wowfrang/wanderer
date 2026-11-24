import SwiftUI
import WandererCore

struct TripView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tripId: String
    @Binding var path: NavigationPath

    @State private var renamingTrip = false
    @State private var editingDay: Day?
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var showImport = false

    var body: some View {
        let trip = try? model.store.trip(id: tripId)
        let days = model.days(tripId)
        let history = model.finishedSessions(tripId)
        List {
            Section {
                ForEach(days) { day in
                    NavigationLink(value: Route.day(day.id)) { DayRow(day: day) }
                        .contextMenu {
                            Button("Edit day…") { beginEdit(day) }
                            Button("Delete day", role: .destructive) { model.perform { try $0.deleteDay(day.id) } }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.perform { try $0.deleteDay(day.id) } }
                            Button("Edit") { beginEdit(day) }
                        }
                }
                .onMove { from, to in
                    var ordered = days
                    ordered.move(fromOffsets: from, toOffset: to)
                    model.perform { store in
                        for (i, day) in ordered.enumerated() {
                            var d = day
                            d.position = i
                            try store.save(d)
                        }
                    }
                }
                Button {
                    model.perform { try $0.addDay(tripId: tripId, name: "Day \(days.count + 1)") }
                } label: {
                    Label("Add day", systemImage: "plus")
                }
            } header: {
                Eyebrow("Days")
            }

            if !history.isEmpty {
                Section {
                    ForEach(history) { s in
                        NavigationLink(value: Route.summary(s.id)) { HistoryRow(session: s, dayName: days.first { $0.id == s.dayId }?.name) }
                    }
                } header: {
                    Eyebrow("Walked")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(trip?.name ?? "Trip")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename trip…") { name = trip?.name ?? ""; renamingTrip = true }
                    Button("Import another itinerary…") { showImport = true }
                    Button("Delete trip", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Rename trip", isPresented: $renamingTrip) {
            TextField("Name", text: $name)
            Button("Save") {
                guard var t = trip else { return }
                t.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? t.name : name
                t.updatedAt = .now
                model.perform { try $0.save(t) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(trip?.name ?? "trip")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete trip and its history", role: .destructive) {
                if model.live.map({ live in days.contains { $0.id == live.session.dayId } }) == true { model.endLiveSession() }
                model.perform { try $0.deleteTrip(tripId) }
                dismiss()
            }
        }
        .sheet(item: $editingDay) { day in
            DayEditor(day: day)
        }
        .sheet(isPresented: $showImport) {
            ImportView { trip in path.append(Route.trip(trip.id)) }
        }
    }

    private func beginEdit(_ day: Day) { editingDay = day }
}

private struct DayRow: View {
    @Environment(AppModel.self) private var model
    let day: Day

    var body: some View {
        let places = model.places(day.id)
        let distance = model.plannedDistance(places)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.name).font(.body.weight(.semibold))
                if model.live?.session.dayId == day.id {
                    Text("Exploring").font(.caption.weight(.semibold)).foregroundStyle(Color.signal)
                }
            }
            HStack(spacing: 6) {
                if let title = DayFormat.title(day) { Text(title); Text("·") }
                Text(places.count == 1 ? "1 place" : "\(places.count) places")
                if distance.metres > 0 {
                    Text("·")
                    Text((distance.isEstimate ? "≈ " : "") + Format.distance(distance.metres))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryRow: View {
    let session: ExplorationSession
    let dayName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dayName ?? "Deleted day").font(.body.weight(.medium))
            HStack(spacing: 6) {
                Text(session.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                Text("·")
                Text(Format.distance(session.distance))
                if let end = session.endedAt {
                    Text("·")
                    Text(Format.duration(end.timeIntervalSince(session.startedAt)))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }
}

struct DayEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let day: Day
    @State private var name = ""
    @State private var hasDate = false
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Toggle("Date", isOn: $hasDate)
                if hasDate {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
            }
            .navigationTitle("Edit day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var d = day
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { d.name = trimmed }
                        d.date = hasDate ? DayFormat.string(date) : nil
                        model.perform { try $0.save(d) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = day.name
                if let s = day.date, let d = DayFormat.parse(s) { date = d; hasDate = true }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
