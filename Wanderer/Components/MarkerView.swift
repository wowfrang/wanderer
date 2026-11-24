import SwiftUI
import WandererCore

enum MarkerState {
    case planned, next, visited, skipped
}

/// Numbered destination marker. Deliberately plain: a disc, a number, a hairline.
struct MarkerView: View {
    let number: Int
    var state: MarkerState = .planned
    var selected = false

    private var size: CGFloat { state == .next ? 34 : (selected ? 32 : 26) }

    var body: some View {
        ZStack {
            switch state {
            case .planned:
                Circle().fill(Color(UIColor.systemBackground))
                Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.primary)
            case .next:
                Circle().fill(Color.signal)
                Circle().strokeBorder(Color.white, lineWidth: 2)
                Text("\(number)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            case .visited:
                Circle().fill(Color(UIColor.systemGray3))
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(UIColor.systemBackground))
            case .skipped:
                Circle().fill(Color(UIColor.systemBackground).opacity(0.8))
                Circle().strokeBorder(Color(UIColor.systemGray2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(UIColor.systemGray))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(state == .visited ? 0.05 : 0.18), radius: 3, y: 1)
        .overlay {
            if selected {
                Circle().strokeBorder(Color.signal.opacity(0.5), lineWidth: 3).frame(width: size + 8, height: size + 8)
            }
        }
        .animation(.snappy, value: selected)
        .animation(.snappy, value: state)
        .contentShape(Circle().inset(by: -8))
    }
}

/// A bottom panel that is always present over the map: a compact header, and a list that
/// slides out when expanded. Dragging (or tapping the grabber) toggles it; the list area
/// itself scrolls normally.
struct BottomPanel<Header: View, Content: View>: View {
    @Binding var expanded: Bool
    var expandedHeight: CGFloat
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    @GestureState private var drag: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(UIColor.tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .padding(.top, 7)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                header()
            }
            .contentShape(Rectangle())
            .onTapGesture { } // keeps taps on header controls from falling through to the map
            .gesture(
                DragGesture(minimumDistance: 10)
                    .updating($drag) { value, state, _ in state = value.translation.height }
                    .onEnded { value in
                        let predicted = value.predictedEndTranslation.height
                        withAnimation(.snappy(duration: 0.3)) {
                            if predicted < -40 { expanded = true } else if predicted > 40 { expanded = false }
                        }
                    }
            )
            if expanded {
                Divider()
                content()
                    .frame(height: expandedHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .offset(y: max(-20, min(40, drag * 0.25)))
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.10), radius: 14, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Reports a view's height so the map can pad its camera around the panel.
struct HeightReader: ViewModifier {
    @Binding var height: CGFloat
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { height = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in height = h }
            }
        }
    }
}

extension View {
    func readHeight(_ height: Binding<CGFloat>) -> some View { modifier(HeightReader(height: height)) }
}
