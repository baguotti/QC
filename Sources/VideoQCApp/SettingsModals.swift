import SwiftUI
import AppKit

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
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.playColor)
                        Text(title)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(palette.textMain)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
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
                        Text("DONE")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
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
        withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
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
        SettingsModalShell(isPresented: $isPresented, title: "SYNCED PROJECTS // QCpie", icon: "icloud.fill") {
            notesSyncSection
        }
    }
    
    private var notesSyncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROJECTS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMuted)
                    .tracking(0.5)
                
                Spacer()
                
                Text(syncStatusText)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(syncStatusColor)
                    .lineLimit(1)
            }
            
            if syncStatus.state == .unavailable {
                Text("No sync server is configured in this build.")
                    .font(.system(size: 10))
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
                    syncButton("ADD", primary: true) { addSyncProject(password: syncPasswordDraft) }
                        .disabled(NotesSync.deriveKeys(password: syncPasswordDraft) == nil)
                    syncButton("GENERATE") { addSyncProject(password: NotesSync.generatePassword(), copy: true) }
                }
                
                Text("Each project has its own password; everyone using it shares that project's notes. Passwords are 8+ characters, not case-sensitive (longer is safer: anyone who guesses one can read its notes). A clip joins the project that already has notes for it, otherwise the DEFAULT project when it gets notes; change it from the Notes panel. Notes are encrypted on this Mac before upload. Clips match by file name and size, so each person can keep files in any folder.")
                    .font(.system(size: 9))
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
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(isRevealed ? project.password : String(repeating: "•", count: min(project.password.count, 16)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(palette.textMain)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .studioBox(background: palette.bgSubtle, border: palette.borderLine)
            syncButton(isDefault ? "DEFAULT" : "MAKE DEFAULT", primary: isDefault) {
                defaultSyncProjectID = project.id
                saveSyncProjects()
            }
            syncButton(isRevealed ? "HIDE" : "SHOW") {
                if isRevealed { revealedProjectIDs.remove(project.id) } else { revealedProjectIDs.insert(project.id) }
            }
            syncButton("COPY") { copyToPasteboard(project.password) }
            syncButton("REMOVE") {
                syncProjects.removeAll { $0.id == project.id }
                if defaultSyncProjectID == project.id { defaultSyncProjectID = syncProjects.first?.id }
                saveSyncProjects()
            }
        }
    }
    
    private func syncField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
    }
    
    private var syncStatusText: String {
        switch syncStatus.state {
        case .unavailable: return "UNAVAILABLE"
        case .off: return "OFF"
        case .on: return "ON"
        case .upToDate:
            if let date = syncStatus.lastReceived {
                return "UP TO DATE · LAST CHANGE \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "UP TO DATE"
        case .offline: return "OFFLINE · SAVED LOCALLY"
        case .failed(let message): return message.uppercased()
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
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

/// Launch defaults set in User Settings. Read once when the engine and window are created; changing one applies on
/// next launch (autoplay, waveforms and queue/specs views are live settings and apply immediately).
enum UserPreferences {
    static let startMutedKey = "prefStartMuted"
    static let linkSlotsKey = "prefLinkSlots"
    static let clipInfoOverlayKey = "prefClipInfoOverlay"
    static let showQueueKey = "prefShowQueue"

    static var startMuted: Bool { UserDefaults.standard.bool(forKey: startMutedKey) }
    static var linkSlots: Bool { UserDefaults.standard.object(forKey: linkSlotsKey) as? Bool ?? true }
    static var showQueue: Bool { UserDefaults.standard.object(forKey: showQueueKey) as? Bool ?? true }
    static var clipInfoOverlay: ClipInfoOverlayMode {
        UserDefaults.standard.string(forKey: clipInfoOverlayKey).flatMap(ClipInfoOverlayMode.init(rawValue:)) ?? .resolution
    }
}

struct UserSettingsModalView: View {
    @Binding var isPresented: Bool
    @ObservedObject var engine: PlayerEngine
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @AppStorage("reviewerName") private var reviewerName: String = ""
    @AppStorage("queueDisplayMode") private var queueDisplayMode: String = "inline"
    @AppStorage("specsDisplayMode") private var specsDisplayMode: String = "inline"
    @AppStorage(UserPreferences.startMutedKey) private var startMuted: Bool = false
    @AppStorage(UserPreferences.linkSlotsKey) private var linkSlots: Bool = true
    @AppStorage(UserPreferences.showQueueKey) private var showQueue: Bool = true
    @AppStorage(UserPreferences.clipInfoOverlayKey) private var clipInfoOverlay: String = ClipInfoOverlayMode.resolution.rawValue
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    var body: some View {
        SettingsModalShell(isPresented: $isPresented, title: "USER SETTINGS // QCpie", icon: "person.crop.circle.fill") {
            section("01 // REVIEWER") {
                row("Your name", detail: "Shown as the author of your notes and replies.") {
                    TextField("Your name", text: $reviewerName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(width: 200)
                        .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
            }
            
            section("02 // PLAYBACK") {
                row("Autoplay", detail: "Play a clip from the start when it is selected in the queue (A).") {
                    toggle($engine.isAutoplayEnabled)
                }
                row("Start muted", detail: "Audio is muted when QCpie opens.", launch: true) {
                    toggle($startMuted)
                }
                row("Link A / B", detail: "Slots A and B play and step together when QCpie opens.", launch: true) {
                    toggle($linkSlots)
                }
                row("Clip info overlay", detail: "Overlay shown on the viewer when QCpie opens.", launch: true) {
                    Picker("", selection: $clipInfoOverlay) {
                        ForEach(ClipInfoOverlayMode.allCases, id: \.rawValue) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
            }
            
            section("03 // QUEUE & SPECS") {
                row("Player queue", detail: "Show the queue panel when QCpie opens.", launch: true) {
                    toggle($showQueue)
                }
                row("Queue view", detail: "List rows or thumbnails in the Player queue.") {
                    choice(listOrThumbs, selection: $queueDisplayMode)
                }
                row("Specs view", detail: "List rows or thumbnails in the Specs tab.") {
                    choice(listOrThumbs, selection: $specsDisplayMode)
                }
                row("Waveforms", detail: "Draw the audio waveform under the timeline (decodes each clip's audio once).") {
                    toggle($engine.drawsWaveforms)
                }
            }
            
            Text("Settings marked NEXT LAUNCH apply the next time QCpie opens; the others apply immediately.")
                .font(.system(size: 9))
                .foregroundColor(palette.textSubtle)
        }
    }
    
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            VStack(spacing: 0) {
                content()
            }
            .studioBox(background: palette.bgPanel, border: palette.borderLine)
        }
    }
    
    private func row<Control: View>(_ title: String, detail: String, launch: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textMain)
                    if launch {
                        Text("NEXT LAUNCH")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textSubtle)
                    }
                }
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundColor(palette.textSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
    
    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(themeManager.currentTheme.playColor)
    }
    
    private struct Option {
        let value: String
        let label: String
    }
    
    private let listOrThumbs = [Option(value: "inline", label: "LIST"), Option(value: "thumbnail", label: "THUMBS")]
    
    private func choice(_ options: [Option], selection: Binding<String>) -> some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection.wrappedValue == option.value
                Button(action: { selection.wrappedValue = option.value }) {
                    Text(option.label.uppercased())
                        .font(.system(size: 9, weight: isSelected ? .black : .bold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundColor(isSelected ? palette.primaryBtnFg : palette.textMuted)
                        .background(isSelected ? palette.primaryBtnBg : palette.bgSubtle)
                        .cornerRadius(StudioTheme.cornerRadius)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
