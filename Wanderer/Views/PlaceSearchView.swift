import SwiftUI
import MapKit
import WandererCore

struct PlaceSearchResult {
    var name: String
    var address: String?
    var coordinate: Coordinate
    var category: String?
}

@MainActor
@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    var results: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func update(query: String, near: Coordinate?) {
        if let near {
            completer.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated { self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

/// Apple Maps search, biased to the area of the day being planned.
struct PlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let near: Coordinate?
    let onPick: (PlaceSearchResult) -> Void

    @State private var query = ""
    @State private var completer = SearchCompleter()
    @State private var resolving = false

    var body: some View {
        NavigationStack {
            List(completer.results, id: \.self) { completion in
                Button {
                    pick(completion)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completion.title).foregroundStyle(.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if resolving { ProgressView() }
                else if completer.results.isEmpty {
                    Text(query.isEmpty ? "Search Apple Maps for a place or address." : "No results")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Place or address")
            .onChange(of: query) { _, q in completer.update(query: q, near: near) }
            .navigationTitle("Add place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        resolving = true
        Task {
            defer { resolving = false }
            let request = MKLocalSearch.Request(completion: completion)
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
            let candidate = GeocodeCandidate(mapItem: item)
            onPick(PlaceSearchResult(name: completion.title, address: candidate.address,
                                     coordinate: candidate.coordinate, category: item.categoryName))
            dismiss()
        }
    }
}
