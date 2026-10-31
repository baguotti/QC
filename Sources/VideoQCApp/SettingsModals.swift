import SwiftUI
import AppKit
import VideoQCLib

/// Shared chrome for the settings popups opened from the gear menu: scrim, header, scrolling body, DONE footer.
struct SettingsModalShell<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    var body: some View {
        ZStack {
            Color.black.opacity(isPresented ? 0.65 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture { dismiss() }
            
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: StudioTheme.scaleFont(13), weight: .bold))
                            .foregroundColor(themeManager.currentTheme.playColor)
                        Text(title)
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundColor(palette.textMain)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Text("Close (Esc)")
                            .font(.ui(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 20) {
                        content
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 540)
                .background(palette.bgMain)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Text("Done")
                            .font(.ui(size: 11, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.primaryBtnFg)
                            .background(palette.primaryBtnBg)
                            .cornerRadius(StudioTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
            }
            .frame(width: 640)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.45), radius: 28, x: 0, y: 14)
        }
        .allowsHitTesting(isPresented)
    }
    
    private func dismiss() {
        withAnimation(Motion.fade) { isPresented = false }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
}

// MARK: - Synced Projects

struct NotesSyncModalView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @ObservedObject private var syncStatus = NotesSyncStatus.shared
    @State private var syncProjects: [NotesSyncProject] = NotesSyncProject.loadAll()
    @State private var defaultSyncProjectID: UUID? = NotesSyncProject.defaultID(in: NotesSyncProject.loadAll())
    @State private var newProjectName: String = ""
    @State private var syncPasswordDraft: String = ""
    @State private var revealedProjectIDs: Set<UUID> = []
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    var body: some View {
        SettingsModalShell(isPresented: $isPresented, title: "Synced Projects", icon: "icloud.fill") {
            notesSyncSection
        }
    }
    
    private var notesSyncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.textMuted)
                
                Spacer()
                
                Text(syncStatusText)
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(syncStatusColor)
                    .lineLimit(1)
            }
            
            if syncStatus.state == .unavailable {
                Text("No sync server is configured in this build.")
                    .font(.system(size: StudioTheme.scaleFont(10)))
                    .foregroundColor(palette.textSubtle)
            } else {
                ForEach(syncProjects) { project in
                    syncProjectRow(project)
                }
                
                HStack(spacing: 8) {
                    syncField("Project name", text: $newProjectName)
                        .frame(width: 150)
                    syncField("Type a password or paste one", text: $syncPasswordDraft)
                        .onSubmit { addSyncProject(password: syncPasswordDraft) }
                    syncButton("Add", primary: true) { addSyncProject(password: syncPasswordDraft) }
                        .disabled(NotesSync.deriveKeys(password: syncPasswordDraft) == nil)
                    syncButton("Generate") { addSyncProject(password: NotesSync.generatePassword(), copy: true) }
                }
                
                Text("Each project has its own password; everyone using it shares that project's notes. Passwords are 8+ characters, not case-sensitive (longer is safer: anyone who guesses one can read its notes). A clip joins the project that already has notes for it, otherwise the DEFAULT project when it gets notes; change it from the Notes panel. Notes are encrypted on this Mac before upload. Clips match by file name and size, so each person can keep files in any folder.")
                    .font(.system(size: StudioTheme.scaleFont(9)))
                    .foregroundColor(palette.textSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private func syncProjectRow(_ project: NotesSyncProject) -> some View {
        let isDefault = project.id == defaultSyncProjectID
        let isRevealed = revealedProjectIDs.contains(project.id)
        return HStack(spacing: 8) {
            Text(project.displayName)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(isRevealed ? project.password : String(repeating: "•", count: min(project.password.count, 16)))
                .font(.ui(size: 11))
                .foregroundColor(palette.textMain)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .studioBox(background: palette.bgSubtle, border: palette.borderLine)
            syncButton(isDefault ? "Default" : "Make Default", primary: isDefault) {
                defaultSyncProjectID = project.id
                saveSyncProjects()
            }
            syncButton(isRevealed ? "Hide" : "Show") {
                if isRevealed { revealedProjectIDs.remove(project.id) } else { revealedProjectIDs.insert(project.id) }
            }
            syncButton("Copy") { copyToPasteboard(project.password) }
            syncButton("Remove") {
                syncProjects.removeAll { $0.id == project.id }
                if defaultSyncProjectID == project.id { defaultSyncProjectID = syncProjects.first?.id }
                saveSyncProjects()
            }
        }
    }
    
    private func syncField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.ui(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
    }
    
    private var syncStatusText: String {
        switch syncStatus.state {
        case .unavailable: return "Unavailable"
        case .off: return "OFF"
        case .on: return "ON"
        case .upToDate:
            if let date = syncStatus.lastReceived {
                return "Up to date · last change \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "Up to date"
        case .offline: return "Offline · saved locally"
        case .failed(let message): return message
        }
    }
    
    private var syncStatusColor: Color {
        switch syncStatus.state {
        case .on, .upToDate: return themeManager.currentTheme.playColor
        case .offline, .failed: return Color.orange
        case .off, .unavailable: return palette.textSubtle
        }
    }
    
    private func syncButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .foregroundColor(primary ? palette.primaryBtnFg : palette.textMain)
                .studioBox(background: primary ? palette.primaryBtnBg : palette.bgSubtle, border: palette.borderLine)
        }
        .buttonStyle(.plain)
    }
    
    private func addSyncProject(password: String, copy: Bool = false) {
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NotesSync.deriveKeys(password: password) != nil else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = NotesSyncProject(name: name.isEmpty ? "Project \(syncProjects.count + 1)" : name, password: password)
        syncProjects.append(project)
        if defaultSyncProjectID == nil { defaultSyncProjectID = project.id }
        newProjectName = ""
        syncPasswordDraft = ""
        if copy {
            copyToPasteboard(password)
            revealedProjectIDs.insert(project.id)
        }
        saveSyncProjects()
    }
    
    private func saveSyncProjects() {
        NotesSyncProject.save(syncProjects, defaultID: defaultSyncProjectID)
        NotesSyncProject.applySaved()
    }
    
    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - User Settings

/// Behind the picture (seen through transparent images and around graphics with alpha).
enum ViewerBackground: String, CaseIterable {
    case theme = "Theme", black = "Black", grey = "Grey", checkerboard = "Checkerboard"

    static var current: ViewerBackground {
        UserDefaults.standard.string(forKey: UserPreferences.viewerBackgroundKey).flatMap(Self.init(rawValue:)) ?? .theme
    }

    /// Fill behind the still frames (nil: clear, the viewport's theme colour shows through).
    var canvasColor: CGColor? {
        switch self {
        case .theme: return nil
        case .black: return NSColor.black.cgColor   // design-ok: drawn behind media
        case .grey: return NSColor(white: 0.5, alpha: 1).cgColor   // design-ok: drawn behind media
        case .checkerboard:
            let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor(white: 0.8, alpha: 1).setFill(); rect.fill()   // design-ok: drawn behind media
                NSColor(white: 0.6, alpha: 1).setFill()   // design-ok: drawn behind media
                NSRect(x: 0, y: 0, width: 8, height: 8).fill()
                NSRect(x: 8, y: 8, width: 8, height: 8).fill()
                return true
            }
            return NSColor(patternImage: tile).cgColor
        }
    }
}

/// Queue order (User Settings → General → Queue). Names compare naturally ("v9" before "v10"). Date and size come from
/// `QueueSortKeys`, filled off the main thread when files are scanned; files without them count as oldest / smallest.
enum QueueSort: String, CaseIterable {
    case name = "Name", newest = "Newest First", largest = "Largest First"
    static let key = "prefQueueSort"
    /// Posted when the setting changes: the queue re-sorts (after reading dates and sizes off the main thread).
    static let changed = Notification.Name("QCpieQueueSortChanged")
    static var current: QueueSort { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .name }

    /// Sorts one folder's files. Files without keys count as oldest / smallest, so the order stays consistent.
    func sorted(_ files: [URL], keys: [String: QueueSortKeys.Keys]) -> [URL] {
        let byName = { (a: URL, b: URL) in a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending }
        switch self {
        case .name:
            return files.sorted(by: byName)
        case .newest:
            return files.sorted { a, b in
                let da = keys[a.path]?.date ?? .distantPast, db = keys[b.path]?.date ?? .distantPast
                return da != db ? da > db : byName(a, b)
            }
        case .largest:
            return files.sorted { a, b in
                let sa = keys[a.path]?.size ?? 0, sb = keys[b.path]?.size ?? 0
                return sa != sb ? sa > sb : byName(a, b)
            }
        }
    }
}

/// Modification date and size per queued file, for date/size sorting without touching the disk on the main thread.
enum QueueSortKeys {
    struct Keys: Sendable { let date: Date; let size: Int64 }
    nonisolated(unsafe) private static var keys: [String: Keys] = [:]
    private static let lock = NSLock()

    static func snapshot() -> [String: Keys] { lock.withLock { keys } }

    /// Reads the missing ones (call off the main thread).
    nonisolated static func fill(_ urls: [URL]) {
        let missing = lock.withLock { urls.filter { keys[$0.path] == nil } }
        var found: [String: Keys] = [:]
        for url in missing {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            found[url.path] = Keys(date: attributes[.modificationDate] as? Date ?? .distantPast,
                                   size: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
        lock.withLock { keys.merge(found) { _, new in new } }
    }
}

/// User Settings keys. Launch defaults are read once when the engine and window are created (a change applies at the
/// next launch: the row says so); the rest are read where they're used.
enum UserPreferences {
    static let startMutedKey = "prefStartMuted"
    static let linkSlotsKey = "prefLinkSlots"
    static let clipInfoOverlayKey = "prefClipInfoOverlay"
    static let showQueueKey = "prefShowQueue"
    static let zoomFollowsCursorKey = "prefZoomFollowsCursor"
    static let lineTargetHexKey = "prefLineTargetHex"
    static let lineSensitivityKey = "prefLineSensitivity"
    static let lineOffColorKey = "prefLineOffColor"
    static let lineAnyColorKey = "prefLineAnyColor"
    static let lineSplitSeamsKey = "prefLineSplitSeams"
    static let lineEdgeDepthKey = "prefLineEdgeDepth"
    static let defaultZoomKey = "prefDefaultZoom"            // "keep" | "fit" | "100"
    static let loopKey = "prefLoop"
    static let shiftStepKey = "prefShiftStep"                // frames; 0 = one second
    static let defaultCompareKey = "prefDefaultCompare"      // CompareMode raw value
    static let resumePositionKey = "prefResumePosition"
    static let resumePositionsKey = "resumePositions"        // path → frame
    static let safeAreaKey = "prefSafeArea"                  // SafeAreaMode raw value
    static let viewerBackgroundKey = "prefViewerBackground"  // ViewerBackground raw value
    static let includeSubfoldersKey = "prefIncludeSubfolders"
    static let restoreQueueKey = "prefRestoreQueue"
    static let lastQueueKey = "lastQueueInputs"              // the queue's files at quit
    static let autoLineCheckKey = "prefAutoLineCheck"

    static var startMuted: Bool { UserDefaults.standard.bool(forKey: startMutedKey) }
    static var linkSlots: Bool { UserDefaults.standard.object(forKey: linkSlotsKey) as? Bool ?? true }
    static var showQueue: Bool { UserDefaults.standard.object(forKey: showQueueKey) as? Bool ?? true }
    static var zoomFollowsCursor: Bool { UserDefaults.standard.object(forKey: zoomFollowsCursorKey) as? Bool ?? true }
    static var lineTargetHex: String { UserDefaults.standard.string(forKey: lineTargetHexKey) ?? "#00FF00" }
    static var lineSensitivity: Double { UserDefaults.standard.object(forKey: lineSensitivityKey) as? Double ?? 50 }
    static var lineOffColor: Bool { UserDefaults.standard.object(forKey: lineOffColorKey) as? Bool ?? true }
    static var lineAnyColor: Bool { UserDefaults.standard.bool(forKey: lineAnyColorKey) }
    static var lineSplitSeams: Bool { UserDefaults.standard.bool(forKey: lineSplitSeamsKey) }
    static var lineEdgeDepth: Int { UserDefaults.standard.object(forKey: lineEdgeDepthKey) as? Int ?? 12 }
    /// nil: keep the zoom of the previous clip (the behaviour before this setting).
    static var defaultZoom: String? {
        let value = UserDefaults.standard.string(forKey: defaultZoomKey)
        return value == "keep" ? nil : value
    }
    static var loop: Bool { UserDefaults.standard.object(forKey: loopKey) as? Bool ?? true }
    static var shiftStep: Int { UserDefaults.standard.object(forKey: shiftStepKey) as? Int ?? 5 }
    static var defaultCompare: CompareMode {
        UserDefaults.standard.string(forKey: defaultCompareKey).flatMap(CompareMode.init(rawValue:)) ?? .single
    }
    static var includeSubfolders: Bool { UserDefaults.standard.object(forKey: includeSubfoldersKey) as? Bool ?? true }
    static var restoreQueue: Bool { UserDefaults.standard.bool(forKey: restoreQueueKey) }
    static var autoLineCheck: Bool { UserDefaults.standard.bool(forKey: autoLineCheckKey) }
    static var resumePosition: Bool { UserDefaults.standard.bool(forKey: resumePositionKey) }
    static var safeArea: SafeAreaMode {
        UserDefaults.standard.string(forKey: safeAreaKey).flatMap(SafeAreaMode.init(rawValue:)) ?? .off
    }

    /// Last paused frame per clip (Resume where you left off), the 300 most recent.
    static func savedFrame(for url: URL) -> Int? {
        (UserDefaults.standard.dictionary(forKey: resumePositionsKey)?[url.path] as? [Any])?.first as? Int
    }
    static func saveFrame(_ frame: Int?, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: resumePositionsKey) ?? [:]
        if let frame { all[url.path] = [frame, Date().timeIntervalSince1970] } else { all[url.path] = nil }
        if all.count > 300 {
            let stamp = { (v: Any) in ((v as? [Any])?.last as? Double) ?? 0 }
            for key in all.sorted(by: { stamp($0.value) < stamp($1.value) }).prefix(all.count - 300).map(\.key) { all[key] = nil }
        }
        UserDefaults.standard.set(all, forKey: resumePositionsKey)
    }

    static var clipInfoOverlay: ClipInfoOverlayMode {
        UserDefaults.standard.string(forKey: clipInfoOverlayKey).flatMap(ClipInfoOverlayMode.init(rawValue:)) ?? .resolution
    }
}

struct UserSettingsModalView: View {
    @Binding var isPresented: Bool
    @ObservedObject var engine: PlayerEngine
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @AppStorage("reviewerName") private var reviewerName: String = ""
    @AppStorage("queueDisplayMode") private var queueDisplayMode: String = "inline"
    @AppStorage("specsDisplayMode") private var specsDisplayMode: String = "inline"
    @AppStorage(UserPreferences.startMutedKey) private var startMuted: Bool = false
    @AppStorage(UserPreferences.linkSlotsKey) private var linkSlots: Bool = true
    @AppStorage(UserPreferences.showQueueKey) private var showQueue: Bool = true
    @AppStorage(UserPreferences.zoomFollowsCursorKey) private var zoomFollowsCursor: Bool = true
    @AppStorage(ImageSequenceStore.defaultFPSKey) private var sequenceFPS: Double = 25
    @AppStorage(UserPreferences.clipInfoOverlayKey) private var clipInfoOverlay: String = ClipInfoOverlayMode.resolution.rawValue
    @AppStorage(UserPreferences.lineTargetHexKey) private var lineTargetHex: String = "#00FF00"
    @AppStorage(UserPreferences.lineSensitivityKey) private var lineSensitivity: Double = 50
    @AppStorage(UserPreferences.lineOffColorKey) private var lineOffColor: Bool = true
    @AppStorage(UserPreferences.lineAnyColorKey) private var lineAnyColor: Bool = false
    @AppStorage(UserPreferences.lineSplitSeamsKey) private var lineSplitSeams: Bool = false
    @AppStorage(UserPreferences.lineEdgeDepthKey) private var lineEdgeDepth: Int = 12
    @AppStorage(LoudnessTarget.presetKey) private var loudnessTargetID: String = "r128"
    @AppStorage(LoudnessTarget.customIntegratedKey) private var loudnessCustomLUFS: Double = -23
    @AppStorage(LoudnessTarget.customToleranceKey) private var loudnessCustomTolerance: Double = 1
    @AppStorage(LoudnessTarget.customTruePeakKey) private var loudnessCustomTruePeak: Double = -1
    @AppStorage(Notifier.enabledKey) private var notificationsOn: Bool = true
    @AppStorage(Notifier.whileActiveKey) private var notifyWhileActive: Bool = false
    @AppStorage(UserPreferences.defaultZoomKey) private var defaultZoom = "keep"
    @AppStorage(UserPreferences.loopKey) private var loopDefault = true
    @AppStorage(UserPreferences.shiftStepKey) private var shiftStep = 5
    @AppStorage(UserPreferences.defaultCompareKey) private var defaultCompare = CompareMode.single.rawValue
    @AppStorage(UserPreferences.resumePositionKey) private var resumePosition = false
    @AppStorage(UserPreferences.safeAreaKey) private var safeAreaDefault = SafeAreaMode.off.rawValue
    @AppStorage(QueueSort.key) private var queueSort = QueueSort.name.rawValue
    @AppStorage(UserPreferences.includeSubfoldersKey) private var includeSubfolders = true
    @AppStorage(ImageSequenceDetector.minimumFramesKey) private var sequenceMinFrames = 6
    @AppStorage(UserPreferences.restoreQueueKey) private var restoreQueue = false
    @AppStorage(UserPreferences.autoLineCheckKey) private var autoLineCheck = false
    @AppStorage(FrameIOBrowser.startPlaceKey) private var frameioStart = "last"
    @AppStorage("uploadKeepStructure") private var keepSubfolders = false
    @AppStorage(UploadThrottle.maxStreamsKey) private var uploadMaxStreams = 0
    @AppStorage(UploadThrottle.gentleKey) private var gentleUploads = false
    @AppStorage(DownloadQueue.askKey) private var askDownloadFolder = true
    @AppStorage(DownloadQueue.addToQueueKey) private var downloadAddToQueue = false
    @AppStorage(FrameIOLinks.autoLinkKey) private var autoLink = true
    @AppStorage(FrameIOPreview.qualityKey) private var previewQuality = "auto"
    @AppStorage(Notifier.problemsOnlyKey) private var problemsOnly = false
    @State private var downloadFolder = UserDefaults.standard.url(forKey: DownloadQueue.folderKey)
    @State private var maintenanceNote: String?
    @ObservedObject private var notifier = Notifier.shared
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private enum Pane: String, CaseIterable {
        case general = "General", checks = "Checks", frameio = "Frame.io", notifications = "Notifications"
        case appearance = "Appearance"
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .checks: return "checkmark.seal"
            case .frameio: return "icloud.and.arrow.up"
            case .notifications: return "bell"
            case .appearance: return "paintpalette"
            }
        }
    }
    @AppStorage(UserSettingsModalView.paneKey) private var pane: Pane = .general
    static let paneKey = "userSettingsPane"
    /// ⌘, (app menu → Settings…): opens User Settings, or closes it when open.
    static let toggle = Notification.Name("QCpieToggleUserSettings")
    @AppStorage(Notifier.soundKey) private var notificationSound: Bool = false

    /// The sidebar's top line, like an account label: whose settings these are.
    private var ownerLabel: String {
        let name = reviewerName.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? NSFullUserName() : name).uppercased()
    }

    var body: some View {
        SidebarModalShell(isPresented: $isPresented, title: "User Settings", width: 780, height: 640, resizeKey: "userSettingsSize") {
            Text(ownerLabel)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ForEach(Pane.allCases, id: \.self) { item in
                SidebarRow(title: item.rawValue, icon: item.icon, isSelected: pane == item, isLightMode: isLightMode) {
                    pane = item
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 22) {
                Text(pane.rawValue)
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundColor(palette.textMain)
                switch pane {
                case .general: generalPane
                case .checks: checksPane
                case .frameio: frameioPane
                case .notifications: notificationsPane
                case .appearance: ThemeSettingsView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    // MARK: Pages

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("You") {
                row("person.crop.circle", "Reviewer name", "Shown as the author of your notes and replies.") {
                    TextField(NSFullUserName(), text: $reviewerName)
                        .textFieldStyle(.roundedBorder)
                        .font(.ui(size: 12))
                        .frame(width: 180)
                }
            }
            settingsSection("Playback") {
                row("play.circle", "Autoplay", "Play a clip from the start when it's selected in the queue (A).") {
                    toggle($engine.isAutoplayEnabled)
                }
                rowDivider
                row("speaker.slash", "Start muted", "Audio is muted when QCpie opens.", launch: true) { toggle($startMuted) }
                rowDivider
                row("link", "Link A / B", "Slots A and B play and step together when QCpie opens.", launch: true) { toggle($linkSlots) }
                rowDivider
                row("repeat", "Loop playback", "Start over at the end of the clip (⌘L switches it for this session).", launch: true) {
                    toggle($loopDefault)
                }
                rowDivider
                row("arrow.up.left.and.arrow.down.right", "Zoom when a clip opens", "Keep the current zoom, fit the window, or show every pixel (100 %).") {
                    segmented([Option(value: "keep", label: "Keep"), Option(value: "fit", label: "Fit"), Option(value: "100", label: "100 %")],
                              selection: $defaultZoom)
                }
                rowDivider
                row("forward.frame", "⇧← / ⇧→ step", "How far Shift + arrow jumps.") {
                    Picker("", selection: $shiftStep) {
                        ForEach([5, 10, 25], id: \.self) { Text("\($0) frames").tag($0) }
                        Text("1 second").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("rectangle.split.2x1", "Compare mode", "Used when slot B gets its first clip (different aspect ratios fall back to side by side).") {
                    Picker("", selection: $defaultCompare) {
                        ForEach(CompareMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("clock.arrow.circlepath", "Resume where you left off", "Reopening a clip goes back to the frame you left it on (not with Autoplay, which starts from the top).") {
                    toggle($resumePosition)
                }
                rowDivider
                row("viewfinder", "Safe areas", "Guides shown when QCpie opens (TikTok only on 9:16 clips).", launch: true) {
                    Picker("", selection: $safeAreaDefault) {
                        ForEach(SafeAreaMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("checkerboard.rectangle", "Viewer background", "Behind the picture: shows through transparent images.") {
                    Picker("", selection: $engine.viewerBackground) {
                        ForEach(ViewerBackground.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("plus.magnifyingglass", "Zoom to cursor", "Scroll-wheel zoom keeps the point under the mouse in place.") {
                    toggle($zoomFollowsCursor)
                }
                rowDivider
                row("photo.stack", "Image sequence rate", "For detected image sequences (right-click one in the queue to change just that one).") {
                    Picker("", selection: $sequenceFPS) {
                        ForEach(QueueSequenceInfo.rates, id: \.self) { rate in
                            Text(QueueSequenceInfo.rateLabel(rate)).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("info.square", "Clip info overlay", "Shown on the viewer when QCpie opens.", launch: true) {
                    Picker("", selection: $clipInfoOverlay) {
                        ForEach(ClipInfoOverlayMode.allCases, id: \.rawValue) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            settingsSection("Queue & Inspect") {
                row("sidebar.left", "Show the queue", "Show the queue panel when QCpie opens.", launch: true) { toggle($showQueue) }
                rowDivider
                row("waveform", "Audio waveforms", "Draw the waveform under the timeline (decodes each clip's audio once).") {
                    toggle($engine.drawsWaveforms)
                }
                rowDivider
                row("list.bullet", "Queue view", "List rows or thumbnails in the Play queue.") {
                    segmented(listOrThumbs, selection: $queueDisplayMode)
                }
                rowDivider
                row("tablecells", "Inspect view", "List rows or thumbnails in the Inspect table.") {
                    segmented(listOrThumbs, selection: $specsDisplayMode)
                }
                rowDivider
                row("arrow.up.arrow.down", "Sort files by", "Order inside each folder. Names sort naturally: v9 before v10.") {
                    Picker("", selection: $queueSort) {
                        ForEach(QueueSort.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: queueSort) { _, _ in NotificationCenter.default.post(name: QueueSort.changed, object: nil) }
                }
                rowDivider
                row("folder", "Include subfolders", "Adding a folder adds the media in its subfolders too. Applies to folders added next.") {
                    toggle($includeSubfolders)
                }
                rowDivider
                row("photo.stack", "Image sequences", "Numbered stills read as one clip from this many frames. Applies to files added next.") {
                    Picker("", selection: $sequenceMinFrames) {
                        Text("Off").tag(0)
                        ForEach([2, 6, 12, 24], id: \.self) { Text("\($0)+ frames").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("tray.and.arrow.down", "Restore the last queue", "Reopen with the files that were queued when QCpie quit.") {
                    toggle($restoreQueue)
                }
            }
            settingsSection("Settings") {
                row("square.and.arrow.up", "Export or import", "Copy these settings, the appearance and Frame.io favourites to another Mac.") {
                    HStack(spacing: 6) {
                        Button("Export…") { maintenanceNote = SettingsTransfer.export() }
                        Button("Import…") { maintenanceNote = SettingsTransfer.importSettings() }
                    }
                    .font(.ui(size: 11))
                }
                rowDivider
                row("trash", "Clear caches", "Frame.io thumbnails and the name/size index used to link clips (rebuilt as you browse).") {
                    Button("Clear") {
                        SettingsTransfer.clearCaches()
                        maintenanceNote = "Caches cleared."
                    }
                    .font(.ui(size: 11))
                }
                rowDivider
                row("arrow.counterclockwise", "Reset all settings", "Back to QCpie's defaults, appearance included. Frame.io favourites and sign-in are kept.") {
                    Button("Reset…") { if SettingsTransfer.confirmReset() { maintenanceNote = "Settings reset. Some apply the next time QCpie opens." } }
                        .font(.ui(size: 11))
                }
                rowDivider
                row("folder.badge.gearshape", "QCpie's files", "Transfer log, upload resume state, Frame.io links and synced notes.") {
                    Button("Show in Finder") { SettingsTransfer.revealSupportFolder() }
                        .font(.ui(size: 11))
                }
            }
            if let maintenanceNote {
                Text(maintenanceNote)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
            }
        }
    }

    private var checksPane: some View {
        let isCustom = loudnessTargetID == "custom"
        return VStack(alignment: .leading, spacing: 22) {
            settingsSection("Line Check", note: "Defaults used each time QCpie opens.") {
                row("play.square.stack", "Check new queues", "Run Line Check whenever a new queue is loaded. It shares the video decoder with playback, so playing during a check can be less smooth.") {
                    toggle($autoLineCheck)
                }
                rowDivider
                row("eyedropper", "Target colour", "The line colour to look for.") {
                    segmented(lineTargets, selection: $lineTargetHex)
                }
                rowDivider
                row("slider.horizontal.3", "Sensitivity", "Higher finds fainter lines (and more false alarms).") {
                    HStack(spacing: 8) {
                        Slider(value: $lineSensitivity, in: 0...100, step: 5)
                            .controlSize(.small)
                            .frame(width: 120)
                        Text("\(Int(lineSensitivity))%")
                            .font(.ui(size: 12))
                            .monospacedDigit()
                            .foregroundColor(palette.textMain)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                rowDivider
                row("arrow.left.and.right.square", "Edge depth", "How many pixels in from each edge are scanned.") {
                    HStack(spacing: 4) {
                        Text("\(lineEdgeDepth) px")
                            .font(.ui(size: 12))
                            .monospacedDigit()
                            .foregroundColor(palette.textMain)
                        Stepper("", value: $lineEdgeDepth, in: 2...40)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
                rowDivider
                row("circle.lefthalf.filled", "Off-colour lines", "Also flag lines close to, but not exactly, the target colour.") { toggle($lineOffColor) }
                rowDivider
                row("paintpalette", "Any colour", "Ignore the target and flag edge lines of any colour.") { toggle($lineAnyColor) }
                rowDivider
                row("rectangle.split.2x1", "Split-screen seams", "Scan the full frame for split-screen seams (slower).") { toggle($lineSplitSeams) }
            }
            settingsSection("Legal Range") {
                row("waveform.path.ecg.rectangle", "Preset", "Used by Frame Check and the Player's zebra.") {
                    Picker("", selection: $engine.legalRangePreset) {
                        ForEach(LegalRangeSpec.presets, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            settingsSection("Loudness", note: "Inspect → Check Loudness passes or fails each file against this target (ITU-R BS.1770-4).") {
                row("speaker.wave.2", "Target", "Delivery loudness spec.") {
                    Picker("", selection: $loudnessTargetID) {
                        ForEach(LoudnessTarget.presets) { preset in
                            Text("\(preset.name)  (\(preset.spec))").tag(preset.id)
                        }
                        Text("Custom").tag("custom")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if isCustom {
                    rowDivider
                    loudnessRow("Integrated", value: $loudnessCustomLUFS, range: -40 ... -5, unit: "LUFS", help: "Target programme loudness.")
                    rowDivider
                    loudnessRow("Tolerance", value: $loudnessCustomTolerance, range: 0.5...5, unit: "LU",
                                help: "How far from the target still passes (warning within 0.5 LU of the edge).")
                    rowDivider
                    loudnessRow("Max true peak", value: $loudnessCustomTruePeak, range: -10...0, unit: "dBTP", help: "Highest allowed true peak.")
                }
            }
        }
    }

    private var frameioPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("Browser") {
                row("house", "Open at", "Where the Frame.io browser opens after signing in.") {
                    Picker("", selection: $frameioStart) {
                        Text("Last Place").tag("last")
                        Text("All Accounts").tag("home")
                        // Read, not observed: the browser publishes on every listing and selection change.
                        let favourites = FrameIOBrowser.shared.favourites
                        if !favourites.isEmpty {
                            Divider()
                            ForEach(favourites) { Text($0.title).tag($0.id) }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }
                rowDivider
                row("play.rectangle", "Preview quality", "Space in the browser. Automatic uses the smallest proxy while a transfer runs.") {
                    Picker("", selection: $previewQuality) {
                        Text("Automatic").tag("auto")
                        Text("Sharp").tag("sharp")
                        Text("Smallest").tag("small")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("link", "Link clips automatically", "Clips with the same name and size as a Frame.io file get its comments.") {
                    toggle($autoLink)
                }
            }
            settingsSection("Uploads") {
                row("folder.badge.plus", "Keep subfolders", "Recreate the queue's subfolders on Frame.io (also in the Upload to card).") {
                    toggle($keepSubfolders)
                        .onChange(of: keepSubfolders) { _, on in if UploadQueue.shared.keepStructure != on { UploadQueue.shared.keepStructure = on } }
                }
                rowDivider
                row("arrow.up.circle", "Parallel streams", "Automatic finds the fastest setting. Lower it to leave bandwidth for others.") {
                    Picker("", selection: $uploadMaxStreams) {
                        Text("Automatic").tag(0)
                        ForEach([2, 4, 8], id: \.self) { Text("Up to \($0)").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("play.circle", "Slow down while playing", "Use 2 streams while the Player plays, so media on the same drive or network plays smoothly.") {
                    toggle($gentleUploads)
                }
            }
            settingsSection("Downloads") {
                row("questionmark.folder", "Ask where to save", "Off: downloads go straight to the folder below.") {
                    toggle($askDownloadFolder)
                }
                rowDivider
                row("folder", "Download folder", downloadFolder?.path ?? "Downloads") {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.directoryURL = downloadFolder
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        UserDefaults.standard.set(url, forKey: DownloadQueue.folderKey)
                        downloadFolder = url
                    }
                    .font(.ui(size: 11))
                }
                rowDivider
                row("text.badge.plus", "Add downloads to the queue", "Downloaded files join the QCpie queue.") {
                    toggle($downloadAddToQueue)
                }
            }
        }
    }

    private var notificationsPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("Notifications") {
                row("bell", "Show notifications", "macOS notifications from QCpie. Click one to go to its tab.") {
                    toggle($notificationsOn)
                        .onChange(of: notificationsOn) { _, on in
                            if on { Task { await notifier.requestAuthorization() } }
                        }
                }
                rowDivider
                row("speaker.wave.2", "Sound", "Play a short chime with each notification.") { toggle($notificationSound) }
                    .disabled(!notificationsOn)
                rowDivider
                row("exclamationmark.triangle", "Only problems", "Uploads, downloads and checks notify only when something failed or was flagged.") {
                    toggle($problemsOnly)
                }
                .disabled(!notificationsOn)
                rowDivider
                row("macwindow", "While QCpie is in front", "Off: they only show while you're in another app.") { toggle($notifyWhileActive) }
                    .disabled(!notificationsOn)
            }
            settingsSection("Notify Me About") {
                ForEach(Array(NotificationKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { rowDivider }
                    NotificationKindRow(kind: kind, isLightMode: isLightMode)
                }
            }
            .disabled(!notificationsOn)
            .opacity(notificationsOn ? 1 : 0.45)
            HStack(spacing: 10) {
                Button("Show Example") { notifier.sendExample() }
                    .font(.ui(size: 11))
                    .disabled(!notificationsOn)
                    .explain("Posts a sample notification now, even with QCpie in front.")
                if notifier.authorization == .denied {
                    Text("macOS is blocking QCpie's notifications.")
                        .font(.ui(size: 11))
                        .foregroundColor(palette.negative)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.ui(size: 11))
                } else if let problem = notifier.problem {
                    Text(problem)
                        .font(.ui(size: 11))
                        .foregroundColor(palette.negative)
                        .lineLimit(2)
                }
            }
        }
        .onAppear { notifier.refreshAuthorization() }
    }

    // MARK: Building blocks

    /// A titled group of rows on a rounded card with hairline dividers (System Settings style).
    private func settingsSection<Rows: View>(_ title: String, note: String? = nil, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.ui(size: 13, weight: .semibold))
                .foregroundColor(palette.textMain)
            if let note {
                Text(note)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgCardSubtle))
                .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine, lineWidth: 1))
        }
    }

    /// Icon, title and a line of explanation on the left; the control on the right. `launch`: takes effect on the
    /// next launch (said in the explanation).
    private func row<Control: View>(_ icon: String, _ title: String, _ detail: String, launch: Bool = false,
                                     @ViewBuilder control: () -> Control) -> some View {
        let explanation = launch ? detail + " Applies the next time QCpie opens." : detail
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: StudioTheme.scaleFont(13)))
                .foregroundColor(palette.textMuted)
                .frame(width: StudioTheme.scale(18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                Text(explanation)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .explain(explanation)
    }

    private var rowDivider: some View {
        Rectangle().fill(palette.borderLine).frame(height: 1).padding(.leading, 12 + StudioTheme.scale(18) + 12)
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private func loudnessRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, help: String) -> some View {
        row("dial.medium", title, help) {
            HStack(spacing: 4) {
                Text(String(format: unit == "LU" ? "±%g %@" : "%g %@", value.wrappedValue, unit))
                    .font(.ui(size: 12))
                    .monospacedDigit()
                    .foregroundColor(palette.textMain)
                Stepper("", value: value, in: range, step: 0.5)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    private struct Option {
        let value: String
        let label: String
    }
    
    private let lineTargets = [Option(value: "#00FF00", label: "Green"), Option(value: "#FF00FF", label: "Magenta"),
                               Option(value: "#000000", label: "Black"), Option(value: "#FFFFFF", label: "White")]
    
    private let listOrThumbs = [Option(value: "inline", label: "List"), Option(value: "thumbnail", label: "Thumbnails")]
    
    private func segmented(_ options: [Option], selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

/// One kind's switch in Settings → Notifications (its own view: `@AppStorage` needs a fixed key per view).
private struct NotificationKindRow: View {
    let kind: NotificationKind
    let isLightMode: Bool
    @AppStorage private var isOn: Bool

    init(kind: NotificationKind, isLightMode: Bool) {
        self.kind = kind
        self.isLightMode = isLightMode
        _isOn = AppStorage(wrappedValue: true, Notifier.key(kind))
    }

    var body: some View {
        let palette = StudioPalette(isLightMode)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                Text(kind.help)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .explain(kind.help)
    }
}

/// User Settings → General → Settings: export / import, reset, caches, the support folder.
@MainActor
enum SettingsTransfer {
    /// Keys exported and reset: every User Settings choice. Prefix "pref" plus the older names.
    private static let extraKeys: Set<String> = [
        "isLightMode", "reviewerName", "queueDisplayMode", "specsDisplayMode", "isAutoplayEnabled", "drawsWaveforms",
        "mediaKindFilter", "imageSequenceFPS", "uploadKeepStructure", "frameioDownloadFolder", "frameioDownloadAddToQueue",
        "userSettingsSize", Notifier.enabledKey, Notifier.whileActiveKey, Notifier.soundKey, Notifier.problemsOnlyKey,
        "QCpie_ActiveThemeID", "QCpie_CurrentThemeData", "QCpie_UserThemePresets", "QCpie_UIButtonZoomLevel"
    ]
    /// Exported (another Mac on the same Frame.io account can use them) but never reset.
    private static let favouriteKeys: Set<String> = ["frameioFavourites", "frameioFavouritePages"]

    private static func isSetting(_ key: String) -> Bool {
        key.hasPrefix("pref") || key.hasPrefix("notify.") || extraKeys.contains(key)
    }

    static func export() -> String? {
        let all = UserDefaults.standard.dictionaryRepresentation().filter { isSetting($0.key) || favouriteKeys.contains($0.key) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QCpie Settings.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0).write(to: url)
            return "Exported \(all.count) settings."
        } catch {
            return "Couldn't export: \(error.localizedDescription)"
        }
    }

    static func importSettings() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let all = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "That file isn't a QCpie settings export."
        }
        let defaults = UserDefaults.standard
        var count = 0
        for (key, value) in all where isSetting(key) || favouriteKeys.contains(key) {
            defaults.set(value, forKey: key)
            count += 1
        }
        return "Imported \(count) settings. Appearance and some others apply the next time QCpie opens."
    }

    static func confirmReset() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Every User Settings choice and the appearance go back to QCpie's defaults. Frame.io sign-in, favourites, notes and the queue are kept."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where isSetting(key) { defaults.removeObject(forKey: key) }
        ThemeManager.shared.resetToDefault()
        return true
    }

    static func clearCaches() {
        FileSystemTreeBuilder.clearCache()
        FrameIOBrowser.clearThumbnailCache()
        Task { await FrameIOLinks.shared.clearIndex() }
    }

    static func revealSupportFolder() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
