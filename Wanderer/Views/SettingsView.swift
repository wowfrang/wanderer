import SwiftUI
import WandererCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    Picker("Directions with", selection: $settings.mapsApp) {
                        ForEach(MapsApp.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Walking pace", value: String(format: "%.1f km/h", settings.walkingSpeed * 3.6))
                        Slider(value: $settings.walkingSpeed, in: 0.8...1.8, step: 0.05)
                    }
                }

                Section {
                    Toggle("Track with the screen locked", isOn: $settings.backgroundTracking)
                    Toggle("Notify when a visit is detected", isOn: $settings.notifyOnVisit)
                        .disabled(!settings.backgroundTracking)
                } header: {
                    Text("Battery")
                } footer: {
                    Text(settings.backgroundTracking
                         ? "GPS keeps running in your pocket at reduced accuracy, so the full route is drawn and visits are detected while the phone is locked. Uses noticeably more battery."
                         : "GPS only runs while Wanderer is open on screen. Steps and walking distance still count in your pocket via the motion sensor, which costs almost no battery. Visits are detected while the app is open, or tap I'm here.")
                }

                Section {
                    slider("Arrival radius", value: $settings.detection.arrivalRadius, range: 10...120, step: 5, unit: "m")
                    slider("Linger time", value: $settings.detection.dwellSeconds, range: 15...300, step: 15, unit: "s")
                    slider("Stroll time", value: $settings.detection.strollSeconds, range: 60...600, step: 30, unit: "s")
                    slider("Max linger speed", value: $settings.detection.maxLingerSpeed, range: 0.2...1.5, step: 0.1, unit: "m/s", decimals: 1)
                    slider("Ignore fixes worse than", value: $settings.detection.maxAccuracy, range: 20...150, step: 5, unit: "m")
                    slider("Exit margin", value: $settings.detection.exitMargin, range: 10...100, step: 5, unit: "m")
                    Button("Reset to defaults") { settings.detection = .default }
                } header: {
                    Text("Visit detection")
                } footer: {
                    Text("A place counts as visited when you're within the arrival radius for the linger time while mostly standing still, or for the stroll time at any pace. Leaving by more than the exit margin resets the clock. Changes apply immediately, including to a day in progress.")
                }

                Section {
                    Button("Add Milan sample trip") { model.loadSample(); dismiss() }
                } footer: {
                    Text("Wanderer keeps everything on this phone. Routes and search use Apple Maps.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: settings.detection) { _, config in model.live?.updateDetection(config) }
            .onChange(of: settings.backgroundTracking) { _, _ in model.live?.backgroundTrackingSettingChanged() }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        unit: String, decimals: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: String(format: "%.\(decimals)f %@", value.wrappedValue, unit))
            Slider(value: value, in: range, step: step)
        }
    }
}
