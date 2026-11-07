import SwiftUI

/// Redraws only its content when `model` publishes, not the view that built it. For values that change often
/// (progress) inside views owned by `ContentView`, whose own redraw covers the whole window.
struct ObservingView<Model: ObservableObject, Content: View>: View {
    @ObservedObject var model: Model
    @ViewBuilder let content: (Model) -> Content

    var body: some View { content(model) }
}
