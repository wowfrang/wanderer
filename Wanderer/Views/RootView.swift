import SwiftUI
import WandererCore

enum Route: Hashable {
    case trip(String)
    case day(String)
    case summary(String)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TripsView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .trip(let id): TripView(tripId: id, path: $path)
                    case .day(let id): DayPlanView(dayId: id)
                    case .summary(let id): SummaryView(sessionId: id)
                    }
                }
        }
        .safeAreaInset(edge: .bottom) {
            if let live = model.live, model.liveMinimized {
                ReturnToLiveBar(live: live) { model.liveMinimized = false }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.live != nil && !model.liveMinimized },
            set: { if !$0 { model.liveMinimized = true } }
        )) {
            if let live = model.live {
                ExploreView(live: live)
                    .environment(model)
                    .tint(.signal)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.live?.appBecameActive()
            case .background: model.live?.appEnteredBackground()
            default: break
            }
        }
        .alert("Storage problem", isPresented: Binding(get: { model.startupError != nil }, set: { if !$0 { model.startupError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.startupError ?? "")
        }
    }
}

private struct ReturnToLiveBar: View {
    let live: LiveSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(live.isPaused ? Color.secondary : Color.signal).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(live.isPaused ? "Exploration paused" : "Exploring")
                        .font(.subheadline.weight(.semibold))
                    if let next = live.nextPlace {
                        Text("Next: \(next.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(live.elapsed(at: context.date)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
        .buttonStyle(.plain)
    }
}
