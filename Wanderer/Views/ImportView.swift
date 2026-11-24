import SwiftUI
import UIKit
import WandererCore

/// Paste → preview → import. Accepts itinerary JSON (any assistant) or a Google Maps
/// directions link. Places are geocoded with Apple Maps before anything is saved, and
/// problems are shown for review instead of being guessed silently.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onImported: (Trip) -> Void

    @State private var text = ""
    @State private var draft: TripDraft?
    @State private var error: String?
    @State private var working = false
    @State private var copiedPrompt = false
    @State private var showSchema = false

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    PreviewList(draft: Binding(get: { draft }, set: { self.draft = $0 }))
                } else {
                    input
                }
            }
            .navigationTitle(draft == nil ? "Import" : "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if draft != nil {
                        Button("Back") { draft = nil }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let draft {
                        Button("Import") { save(draft) }
                            .disabled(!draft.allPlaces.contains { $0.include })
                    } else {
                        Button("Preview") { Task { await preview() } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    }
                }
            }
            .overlay {
                if working {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Finding places in Apple Maps…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .interactiveDismissDisabled(draft != nil)
    }

    private var input: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste an itinerary")
                        .font(.system(.title2, design: .serif))
                    Text("JSON from ChatGPT (or any assistant), or a Google Maps directions link.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if text.isEmpty {
                        Text("{ \"trip_name\": …, \"days\": [ … ] }")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if let s = UIPasteboard.general.string { text = s }
                    } label: { Text("Paste").secondaryButton() }
                    Button { text = "" } label: { Text("Clear").secondaryButton() }
                        .disabled(text.isEmpty)
                }
                .buttonStyle(.plain)

                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("Getting an itinerary")
                    Text("Copy this prompt into ChatGPT, add what you'd like to do, then paste its reply here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = ItineraryFormat.llmPrompt
                        copiedPrompt = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Text(copiedPrompt ? "Prompt copied" : "Copy prompt").secondaryButton()
                    }
                    .buttonStyle(.plain)
                    DisclosureGroup("JSON format", isExpanded: $showSchema) {
                        Text(ItineraryFormat.schemaDescription)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline)
                    Button("Try the Milan sample") { text = ItineraryFormat.sampleMilanJSON() }
                        .font(.subheadline)
                }
            }
            .padding(20)
        }
    }

    private func preview() async {
        error = nil
        working = true
        defer { working = false }
        do {
            var parsed: TripDraft
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http"), var url = URL(string: trimmed) {
                if GoogleMapsURLParser.isShortLink(url) { url = try await ShortLinkExpander.expand(url) }
                parsed = try GoogleMapsURLParser.parse(url.absoluteString)
            } else {
                parsed = try ItineraryParser.parse(text)
            }
            parsed = await ItineraryResolver.resolve(parsed, using: MapKitGeocoder(), cityHint: cityHint(parsed))
            draft = parsed
        } catch let e as ImportError {
            error = e.message
        } catch {
            self.error = "Couldn't read that: \(error.localizedDescription)"
        }
    }

    /// Bias name-only lookups: "Duomo" alone is ambiguous, "Duomo, Milan" isn't.
    private func cityHint(_ draft: TripDraft) -> String? {
        let name = draft.name.split(separator: ",").first.map(String.init) ?? draft.name
        if name.lowercased().contains("trip") || name.lowercased().contains("route") { return nil }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func save(_ draft: TripDraft) {
        do {
            let trip = try model.store.insert(draft)
            model.changed()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            onImported(trip)
        } catch {
            self.error = "Import failed: \(error.localizedDescription)"
        }
    }
}

private struct PreviewList: View {
    @Binding var draft: TripDraft

    var body: some View {
        List {
            Section {
                TextField("Trip name", text: $draft.name)
                    .font(.system(.title3, design: .serif))
                if draft.needsAttentionCount > 0 {
                    Text("\(draft.needsAttentionCount) place\(draft.needsAttentionCount == 1 ? " needs" : "s need") a look. Tap to choose a match; places without a location can be fixed later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.warnings, id: \.self) { w in
                    Text(w).font(.footnote).foregroundStyle(.orange)
                }
            }
            ForEach($draft.days) { $day in
                Section {
                    ForEach($day.places) { $place in
                        DraftPlaceRow(place: $place)
                    }
                } header: {
                    HStack {
                        Eyebrow(day.name)
                        Spacer()
                        if let date = day.date { Eyebrow(date) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct DraftPlaceRow: View {
    @Binding var place: PlaceDraft

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .foregroundStyle(place.include ? .primary : .tertiary)
                if let address = place.address {
                    Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(statusText).font(.caption).foregroundStyle(statusColor)
                if place.resolution == .ambiguous, !place.candidates.isEmpty {
                    Menu {
                        ForEach(place.candidates, id: \.self) { c in
                            Button {
                                place.chosenCoordinate = c.coordinate
                                place.resolution = .resolved
                            } label: {
                                Text([c.name, c.address].compactMap { $0 }.joined(separator: " — "))
                            }
                        }
                    } label: {
                        Text("Choose match").font(.caption.weight(.semibold))
                    }
                }
            }
            Spacer()
            Toggle("", isOn: $place.include).labelsHidden()
        }
    }

    private var statusText: String {
        switch place.resolution {
        case .provided: return "Using coordinates from the itinerary"
        case .resolved: return "Found in Apple Maps"
        case .ambiguous: return place.candidates.count > 1 ? "Several matches; using the first" : "Check the location"
        case .unresolved: return "Not found; will import without a location"
        case .pending: return "Not looked up"
        }
    }

    private var statusColor: Color {
        switch place.resolution {
        case .ambiguous: return .orange
        case .unresolved: return .red
        default: return .secondary
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch place.resolution {
        case .resolved, .provided: Image(systemName: "checkmark").foregroundStyle(.secondary)
        case .ambiguous: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .unresolved: Image(systemName: "xmark").foregroundStyle(.red)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}
