import SwiftUI

/// Redraws only its content when `model` publishes, not the view that built it. For values that change often
/// (progress) inside views owned by `ContentView`, whose own redraw covers the whole window.
struct ObservingView<Model: ObservableObject, Content: View>: View {
    @ObservedObject var model: Model
    @ViewBuilder let content: (Model) -> Content

    var body: some View { content(model) }
}

/// Keeps hover state in its own view: hover held as `@State` on `ContentView` redraws the whole window.
struct HoverReader<Content: View>: View {
    var animation: Animation? = nil
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .onHover { inside in
                if let animation { withAnimation(animation) { hovering = inside } } else { hovering = inside }
            }
    }
}
