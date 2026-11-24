import SwiftUI
import WandererCore

struct PlaceEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var place: Place
    @State private var relocating = false
    @State private var minutes = 0
    @State private var radius = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $place.name)
                    TextField("Category", text: Binding(get: { place.category ?? "" }, set: { place.category = $0.isEmpty ? nil : $0 }))
                    TextField("Address", text: Binding(get: { place.address ?? "" }, set: { place.address = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
                Section {
                    TextField("Notes", text: Binding(get: { place.notes ?? "" }, set: { place.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Opening hours", text: Binding(get: { place.openingHours ?? "" }, set: { place.openingHours = $0.isEmpty ? nil : $0 }))
                    Stepper(value: $minutes, in: 0...480, step: 15) {
                        LabeledContent("Visit", value: minutes == 0 ? "Not set" : Format.duration(Double(minutes) * 60))
                    }
                }
                if let details = place.details {
                    Section("Description") { Text(details).foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent("Location", value: place.coordinate.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "Missing")
                    Button(place.coordinate == nil ? "Find location…" : "Change location…") { relocating = true }
                    VStack(alignment: .leading) {
                        LabeledContent("Arrival radius", value: radius == 0 ? "Default (\(Int(model.settings.detection.arrivalRadius)) m)" : "\(Int(radius)) m")
                        Slider(value: $radius, in: 0...200, step: 5)
                    }
                } footer: {
                    Text("Use a bigger radius for long streets, squares and parks.")
                }
            }
            .navigationTitle("Edit place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        place.visitMinutes = minutes == 0 ? nil : minutes
                        place.radius = radius == 0 ? nil : radius
                        let p = place
                        model.perform { try $0.save(p) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                minutes = place.visitMinutes ?? 0
                radius = place.radius ?? 0
            }
            .sheet(isPresented: $relocating) {
                PlaceSearchView(near: place.coordinate) { result in
                    place.coordinate = result.coordinate
                    if place.address == nil { place.address = result.address }
                }
            }
        }
    }
}
