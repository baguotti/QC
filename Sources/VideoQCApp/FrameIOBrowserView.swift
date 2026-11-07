import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImageIO

/// Right side of the Upload tab: Adobe sign-in, then the Frame.io browser.
struct FrameIOBrowserView: View {
    @ObservedObject var themeManager = ThemeManager.shared   // accent changes redraw
    var isLightMode: Bool
    @ObservedObject var browser = FrameIOBrowser.shared
    /// Row or breadcrumb under a drag.
    @State var dropTarget: String?
    @State var isListTargeted = false
    @State var renameText = ""
    @FocusState var renameFocused: Bool
    @State var metadataRequest: FrameIOMetadataSheet.Request?
    @State var moveItems: MoveRequest?
    @State var stackItems: MoveRequest?
    @State var copyItems: MoveRequest?
    @State var shareRequest: ShareRequest?
    @State var showNewProject = false
    /// The breadcrumbs' "…" (folded start of a long path) is open.
    @State var hiddenCrumbsOpen = false
    /// How favourites show in their row under the header: "bar" (chips) or "list" (a button opening a vertical list).
    /// Both use the same fixed row, switched by the two icons at its right end. (An old "hidden" setting reads as the bar.)
    @AppStorage("frameioFavouritesLayout") var favouritesLayout = "bar"
    /// List layout: the page whose favourites list is open under its tab (nil: closed).
    @State var listOpenPage: Int?
    /// The favourite being dragged to reorder (drops elsewhere ignore it).
    @State var draggingFavourite: String?
    @AppStorage("frameioThumbnails") var showThumbnails = false
    @AppStorage("frameioThumbnailWidth") var thumbnailWidth: Double = 64

    struct ShareRequest: Identifiable {
        let id = UUID()
        let project: String
        let name: String
        let assetIDs: [String]
        /// For the preview (empty when sharing the open folder).
        var items: [FrameIO.Item] = []
    }

    var palette: StudioPalette { StudioPalette(isLightMode) }
    var inFolder: Bool { browser.destination != nil }

    struct MoveRequest: Identifiable {
        let id = UUID()
        let items: [FrameIO.Item]
    }

    var body: some View {
        VStack(spacing: 0) {
            switch browser.signedIn {
            case nil:
                Spacer()
            case false?:
                signInPrompt
            case true?:
                if !benchHides("header") { header }
                if !benchHides("favbar") {
                    favouritesBar
                    Rectangle().fill(palette.borderLine).frame(height: 1)
                }
                if !benchHides("toolbar") { toolbar }
                Rectangle().fill(palette.borderLine).frame(height: 1)
                if benchHides("list") { Spacer() } else { folderList }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bgMain)
        .overlay { FrameIOPreviewOverlay(isLightMode: isLightMode) }
        .overlay(alignment: .bottom) { toastView }
        .onAppear { browser.start() }
        .sheet(item: $shareRequest, onDismiss: { browser.loadShares() }) { request in
            FrameIOShareSheet(request: request, isLightMode: isLightMode)
        }
        .sheet(isPresented: $showNewProject) {
            FrameIONewProjectSheet(isLightMode: isLightMode) { name in browser.newProject(named: name) }
        }
        .sheet(item: $metadataRequest) { request in
            FrameIOMetadataSheet(request: request, isLightMode: isLightMode)
        }
        .sheet(item: $stackItems) { request in
            FrameIOStackSheet(files: request.items, isLightMode: isLightMode) { ordered in
                browser.stack(ordered)
            }
        }
        .sheet(item: $moveItems) { request in
            FrameIOMoveSheet(items: request.items, isCopy: false, isLightMode: isLightMode) { folder, title in
                browser.move(request.items, to: folder, titled: title)
            }
        }
        .sheet(item: $copyItems) { request in
            FrameIOMoveSheet(items: request.items, isCopy: true, isLightMode: isLightMode) { folder, title in
                browser.copy(request.items, to: folder, titled: title)
            }
        }
    }

    // MARK: Signed out

    var signInPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: StudioTheme.scaleFont(34), weight: .light))
                .foregroundColor(palette.textMuted)
            Text("Upload to Frame.io")
                .font(.ui(size: 15, weight: .semibold))
            Text("Sign in with the Adobe account you use for Frame.io.")
                .font(.ui(size: 12))
                .foregroundColor(palette.textMuted)
            Button(action: browser.signIn) {
                Text(browser.isSigningIn ? "Signing In…" : "Sign In with Adobe")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.primaryBtnFg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Radius.segment).fill(palette.primaryBtnBg))
            }
            .buttonStyle(.plain)
            .disabled(browser.isSigningIn)
            if let error = browser.error {
                Text(error)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.negative)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: 420)
    }

    typealias Crumb = FrameIOBrowser.Crumb

}
