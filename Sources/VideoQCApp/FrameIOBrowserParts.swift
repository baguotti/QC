import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImageIO

// Small views and helpers used by the browser: thumbnails, icons, favourites, breadcrumbs, columns, hover.
/// A Frame.io thumbnail for a list row (16:9 box; folders and files without one get an icon). Loaded only when the row
/// is on screen, decoded off the main thread at the displayed size, and kept in a small memory cache.
struct FrameIOThumbnail: View {
    /// Redraws the row when its list redraws for a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
    let item: FrameIO.Item
    let width: Double
    let isLightMode: Bool
    @State private var image: CGImage?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var size: CGSize { CGSize(width: width, height: (width * 9 / 16).rounded()) }
    /// Above 128 pt the small Frame.io thumbnail looks soft: use the high-quality one.
    private var isLarge: Bool { width > 128 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(palette.bgSubtle)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.isFolder ? "folder.fill" : (item.isVersionStack ? "square.stack.3d.up.fill" : "film"))
                    .font(.system(size: StudioTheme.scaleFont(min(16, width / 4))))
                    .foregroundColor(item.isFolder || item.isVersionStack ? palette.accentBlue : palette.textMuted)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: "\(item.thumbnailKey)-\(isLarge)") {
            guard let url = isLarge ? item.largeThumbnailURL : item.thumbnailURL else { image = nil; return }
            image = await FrameIOThumbnailCache.shared.image(for: "\(item.thumbnailKey)-\(isLarge)", url: url,
                                                             maxPixels: isLarge ? 640 : 320)
        }
    }
}

/// A project's icon from Frame.io (the project image), or a Frame.io-style gradient when it has none.
struct FrameIOProjectIcon: View {
    let item: FrameIO.Item
    let isLightMode: Bool
    @State private var image: CGImage?

    var body: some View {
        let side = StudioTheme.scale(22)
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            } else {
                ProjectGradientIcon(projectID: item.id, side: side)
            }
        }
        .frame(width: side, height: side)
        .task(id: item.image) {
            guard let url = item.projectImageURL else { image = nil; return }
            image = await FrameIOThumbnailCache.shared.image(for: "project-\(item.id)", url: url, maxPixels: 96)
        }
    }
}

/// Frame.io draws a gradient for projects without an image (not exposed by the API). The same look, with the
/// gradient picked from the project id so each project keeps its colours.
struct ProjectGradientIcon: View {
    let projectID: String
    let side: CGFloat

    private static let gradients: [(Color, Color)] = [
        (Color(red: 0.42, green: 0.55, blue: 1.00), Color(red: 0.40, green: 0.16, blue: 0.94)),   // blue → violet
        (Color(red: 0.86, green: 0.38, blue: 0.62), Color(red: 0.95, green: 0.55, blue: 0.40)),   // pink → orange
        (Color(red: 0.95, green: 0.47, blue: 0.43), Color(red: 0.97, green: 0.62, blue: 0.50)),   // coral → peach
        (Color(red: 0.78, green: 0.35, blue: 0.67), Color(red: 0.95, green: 0.55, blue: 0.38)),   // magenta → orange
        (Color(red: 0.36, green: 0.80, blue: 0.96), Color(red: 0.30, green: 0.36, blue: 0.94))    // cyan → indigo
    ]

    /// FNV-1a: stable across launches (`hashValue` isn't).
    private var index: Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in projectID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(Self.gradients.count))
    }

    var body: some View {
        let (from, to) = Self.gradients[index]
        RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Ellipse()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: side * 1.3, height: side * 0.7)
                    .rotationEffect(.degrees(-30))
                    .offset(x: side * 0.25, y: side * 0.3)
                    .blur(radius: side * 0.12)
            )
            .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            .frame(width: side, height: side)
    }
}

/// Decoded thumbnails by item (a stack: its current version) and size, capped at 64 MB of decoded pixels.
actor FrameIOThumbnailCache {
    static let shared = FrameIOThumbnailCache()
    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.totalCostLimit = 64 * 1024 * 1024   // by decoded bytes: large thumbnails are ~1 MB each
        return cache
    }()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    func clear() { cache.removeAllObjects() }

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func image(for key: String, url: URL, maxPixels: Int) async -> CGImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached.image }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }
}

/// Row hover highlight kept inside the row, so moving the pointer redraws one row instead of the whole list.
/// One favourites page tab: its name and count; double-click to rename (Return or clicking away saves, Esc cancels:
/// the shortcut router unfocuses the field for both). A dragged favourite chip dropped here moves to this page.
struct FavouritePageTab: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let canDelete: Bool
    let isLightMode: Bool
    @Binding var dragging: String?
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onDropFavourite: (String) -> Void

    @State private var isRenaming = false
    @State private var draft = ""
    @State private var isHovered = false
    @State private var isDropTarget = false
    @FocusState private var focused: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        HStack(spacing: 4) {
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 11, weight: .semibold))
                    .frame(width: max(60, CGFloat(draft.count) * 7))
                    .focused($focused)
                    .onAppear { draft = name; DispatchQueue.main.async { focused = true } }
                    .onChange(of: focused) { _, isFocused in
                        guard !isFocused else { return }
                        let cancelled = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53
                        if !cancelled { onRename(draft) }
                        isRenaming = false
                    }
            } else {
                Text(name)
                    .font(.ui(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected || isHovered ? palette.textMain : palette.textMuted)
                    .lineLimit(1)
            }
            if count > 0 && !isRenaming {
                Text("\(count)")
                    .font(.ui(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(isSelected ? palette.accentBlue : palette.textMuted)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: StudioTheme.scale(24))
        // No box: the page shown is underlined in the accent colour (a drop target or hover gets a faint line).
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(isSelected || isDropTarget ? palette.accentBlue : palette.textMuted.opacity(isHovered ? 0.35 : 0))
                .frame(height: isSelected || isDropTarget ? 2 : 1)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename() }
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename…", action: startRename)
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Text(count > 0 ? "Delete Page (its \(count) favourite\(count == 1 ? "" : "s") move to the page before)" : "Delete Page")
                }
            }
        }
        .onDrop(of: [.utf8PlainText], delegate: FavouritePageDropDelegate(dragging: $dragging, isTargeted: $isDropTarget, onDrop: onDropFavourite))
        .help("\(name): click to show, double-click to rename, drop a favourite here to move it")
    }

    private func startRename() {
        draft = name
        isRenaming = true
    }
}

/// A favourite chip dropped on a page tab.
struct FavouritePageDropDelegate: DropDelegate {
    @Binding var dragging: String?
    @Binding var isTargeted: Bool
    let onDrop: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let dragging else { return false }
        withAnimation(Motion.snap) { onDrop(dragging) }
        self.dragging = nil
        return true
    }
}

/// Reorders favourites live as a dragged chip passes over the others (only favourite drags: `dragging` is set by them).
struct FavouriteDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(Motion.snap) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Picks how many trailing crumbs fit the width it's given and builds just that row. Owns the width, so a resize
/// redraws the breadcrumbs only, not the browser. Widths come from the titles' text (same font as the crumbs) plus each
/// crumb's padding and chevron.
struct CrumbFitter<Row: View>: View {
    let titles: [String]
    @ViewBuilder let row: (_ keep: Int, _ shortenLast: Bool) -> Row
    /// How many crumbs fit (and whether the last must shorten): changes only when that answer does, so a resize
    /// doesn't rebuild the row every frame.
    @State private var fitted: Fit?
    @State private var width: CGFloat = 0

    struct Fit: Equatable {
        let keep: Int
        let shorten: Bool
    }

    var body: some View {
        let fit = fitted ?? Fit(keep: titles.count, shorten: false)
        row(min(fit.keep, titles.count), fit.shorten)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                width = new
                refit()
            }
            .onChange(of: titles) { _, _ in refit() }
    }

    private func refit() {
        let next = Self.fit(titles, in: width)
        if next != fitted { fitted = next }
    }

    @MainActor private static func textWidth(_ title: String, size: CGFloat, bold: Bool) -> CGFloat {
        CrumbTextWidths.width(title, size: size, bold: bold)
    }

    @MainActor private static func fit(_ titles: [String], in available: CGFloat) -> Fit {
        guard available > 0, !titles.isEmpty else { return Fit(keep: titles.count, shorten: false) }
        let size = (TypeScale.snap(12) * TypeScale.factor).rounded()
        let chevron = StudioTheme.scaleFont(9) + 8   // the chevron and the row spacing around it
        let ellipsis = StudioTheme.scaleFont(11) + 12 + chevron
        let widths = titles.indices.map { textWidth(titles[$0], size: size, bold: $0 == titles.count - 1) + 12 }
        for keep in stride(from: titles.count, through: 1, by: -1) {
            let shown = widths.suffix(keep).reduce(0, +) + CGFloat(keep - 1) * chevron
            if shown + (keep < titles.count ? ellipsis : 0) <= available { return Fit(keep: keep, shorten: false) }
        }
        return Fit(keep: 1, shorten: true)
    }
}

/// Crumb title widths by font size, weight and title (the same titles are measured on every resize frame).
@MainActor
enum CrumbTextWidths {
    private static var cache: [String: CGFloat] = [:]

    static func width(_ title: String, size: CGFloat, bold: Bool) -> CGFloat {
        let key = "\(size)|\(bold)|\(title)"
        if let cached = cache[key] { return cached }
        let font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        if cache.count > 2_000 { cache = [:] }
        cache[key] = width
        return width
    }
}

/// One favourite in the Favourites bar: icon, name and where it lives; × on hover.
struct FavouriteChip: View {
    let favourite: FrameIOBrowser.Favourite
    let isCurrent: Bool
    let isLightMode: Bool
    /// The List layout: chips fill the list's width.
    var fullWidth = false
    /// Being dragged to reorder: dimmed in place.
    var isDragging = false
    /// The favourites pages, for Move to Page.
    var pages: [String] = []
    var onMoveToPage: (Int) -> Void = { _ in }
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var level: FrameIOBrowser.Level { favourite.path.last?.level ?? .folder }

    var body: some View {
        HStack(spacing: 7) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(favourite.title)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !favourite.location.isEmpty {
                    Text(favourite.location)
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if fullWidth { Spacer(minLength: 4) }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                    .foregroundColor(palette.textMuted)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(palette.bgSubtle))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help("Remove from Favourites")
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(height: StudioTheme.scale(34))
        .frame(maxWidth: fullWidth ? .infinity : 240, alignment: .leading)
        .opacity(isDragging ? 0.45 : 1)
        .background(RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
            .fill(isCurrent ? palette.accentBlue.opacity(0.18) : (isHovered ? palette.bgSubtle : palette.bgCardSubtle)))
        .overlay(RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
            .stroke(isCurrent ? palette.accentBlue.opacity(0.7) : palette.borderLine, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .contextMenu {
            Button(action: onOpen) { Label("Open", systemImage: "arrow.right.circle") }
            if let url = favourite.webURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in Frame.io", systemImage: "arrow.up.forward.square") }
            }
            if pages.count > 1 {
                Menu {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, name in
                        Button(name) { onMoveToPage(index) }
                            .disabled(index == favourite.page)
                    }
                } label: { Label("Move to Page", systemImage: "rectangle.stack") }
            }
            Divider()
            Button(action: onRemove) { Label("Remove from Favourites", systemImage: "star.slash") }
        }
        .help(([favourite.location, favourite.title].filter { !$0.isEmpty }).joined(separator: " › "))
    }

    @ViewBuilder
    private var icon: some View {
        switch level {
        case .project:
            ProjectGradientIcon(projectID: favourite.path.last?.id ?? "", side: StudioTheme.scale(20))
        case .stack:
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: StudioTheme.scaleFont(13)))
                .foregroundColor(palette.accentBlue)
                .frame(width: StudioTheme.scale(20))
        default:
            Image(systemName: "folder.fill")
                .font(.system(size: StudioTheme.scaleFont(13)))
                .foregroundColor(palette.accentBlue)
                .frame(width: StudioTheme.scale(20))
        }
    }
}

struct HoverBackground: ViewModifier {
    let base: Color
    let hover: Color
    /// False while the row is selected or a drop target (their colour wins).
    let isActive: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isActive && isHovered ? hover : base)
            .onHover { isHovered = $0 }
    }
}

/// Toolbar controls and breadcrumbs: a rounded background on hover (and while `isOn`), like Finder's toolbar.
struct ToolHover: ViewModifier {
    let fill: Color
    var isOn = false
    var isEnabled = true
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                    .fill(isOn || (isEnabled && isHovered) ? fill : .clear)
            )
            .onHover { isHovered = $0 }
            .animation(Motion.hover, value: isHovered)
    }
}

/// Project list columns after the name (fixed widths, scaled with Button Size).
enum ProjectColumn: CaseIterable {
    case updated, storage, created, status

    var title: String {
        switch self {
        case .updated: return "Last Updated"
        case .storage: return "Storage"
        case .created: return "Creation Date"
        case .status: return "Status"
        }
    }

    var width: CGFloat {
        switch self {
        case .updated: return 90
        case .storage: return 80
        case .created: return 160
        case .status: return 64
        }
    }

    /// The columns plus the 10 pt row spacing before each.
    @MainActor static var totalWidth: CGFloat { allCases.reduce(0) { $0 + StudioTheme.scale($1.width) + 10 } }

    func value(for item: FrameIO.Item) -> String {
        switch self {
        case .updated: return item.updatedDate?.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) ?? "—"
        case .storage: return item.storage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case .created: return item.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        case .status: return item.status == nil ? "—" : (item.isInactive ? "Inactive" : "Active")
        }
    }
}

/// Folder and stack contents columns after the name, in the project table's order (fixed widths, scaled with Button Size).
enum ContentColumn: CaseIterable {
    case updated, size, created, kind

    var title: String {
        switch self {
        case .updated: return "Last Updated"
        case .size: return "Size"
        case .created: return "Creation Date"
        case .kind: return "Type"
        }
    }

    var width: CGFloat {
        switch self {
        case .updated: return 90
        case .size: return 80
        case .created: return 160
        case .kind: return 64
        }
    }

    func value(for item: FrameIO.Item) -> String {
        switch self {
        case .updated: return item.updatedDate?.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) ?? "—"
        case .size: return item.isFolder ? "—" : item.displaySize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case .created: return item.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        case .kind:
            if item.isFolder { return "Folder" }
            if item.isVersionStack { return "Stack" }
            let ext = (item.title as NSString).pathExtension
            return ext.isEmpty ? "File" : ext.uppercased()
        }
    }
}

/// The Assets & Queue panel's chevron at the far left of the Frame.io header (⌘⇧← too). Its own view, so toggling the
/// panel doesn't redraw the browser.
struct QueueSleeveToggle: View {
    let isLightMode: Bool
    @AppStorage("uploadQueueOpen") private var isOpen = true

    var body: some View {
        SleeveToggle(side: .leading, isOpen: isOpen, isLightMode: isLightMode,
                     help: isOpen ? "Hide Assets & Queue panel (⌘⇧←)." : "Reveal Assets & Queue panel (⌘⇧←).") {
            isOpen.toggle()
        }
    }
}

/// The right drawer's chevron at the far right of the Frame.io header (⌘⇧→ too): opens / closes the drawer, whose own
/// tabs pick Media Info, Downloads or Log. Starting a download opens it on Downloads, a running one shows its percentage
/// here, and Frame.io rows dropped on it download. The only part of the header that observes `DownloadQueue` (its
/// 5 Hz progress mustn't redraw the browser's list).
struct DrawerTabs: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    let isLightMode: Bool
    @AppStorage("uploadLogOpen") private var isOpen = false
    @AppStorage("uploadDrawerTab") private var tab = "info"
    @ObservedObject private var downloads = DownloadQueue.shared
    @State private var isDropTarget = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        HStack(spacing: 2) {
            if downloads.isRunning {
                Text("\(downloads.percent)%")
                    .font(.ui(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(palette.accentBlue)
                    .padding(.leading, 6)
            }
            SleeveToggle(side: .trailing, isOpen: isOpen, isLightMode: isLightMode,
                         help: isOpen ? "Close the drawer (⌘⇧→)." : "Open Media Info, Downloads & Log (⌘⇧→).") {
                isOpen.toggle()
            }
        }
        .background(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).fill(isDropTarget ? palette.accentBlue.opacity(0.25) : .clear))
        .onDrop(of: [.utf8PlainText], isTargeted: $isDropTarget, perform: DownloadQueue.acceptDrop)
        .onChange(of: downloads.startCount) {
            withAnimation(Motion.sleeve) { tab = "downloads"; isOpen = true }
        }
    }
}
