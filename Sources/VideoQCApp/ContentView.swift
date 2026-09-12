import SwiftUI
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import VideoQCLib

struct ContentView: View {
    @AppStorage("isLightMode") var isLightMode: Bool = false
    @State var selectedTab: AppTab = .player
    @State var showUserGuide: Bool = false
    @State var showFeedbackModal: Bool = false
    @State var showShortcutsModal: Bool = false
    @State var showSettingsPopover: Bool = false
    @State var showThemeModal: Bool = false
    @State var showPropertiesModal: Bool = false
    @State var showAddNoteModal: Bool = false
    @State var showNotesDrawer: Bool = false
    @AppStorage("reviewerName") var reviewerName: String = ""
    @AppStorage("specsDisplayMode") var specsDisplayMode: String = "inline"
    @AppStorage("specsThumbnailSize") var specsThumbnailSize: Double = 50.0
    @State var showSpecsViewOptionsPopover: Bool = false
    @State var propertiesAsset: DeliverableAsset? = nil
    @State var propertiesURL: URL? = nil
    @State var isInspectingProperties: Bool = false
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject private var fileOpenManager = FileOpenManager.shared
    @State var hoverExplanation: String = ""
    @State private var hoveredTab: AppTab? = nil
    
    // Shared Folder & Video Files
    @State var folderURL: URL? = nil
    @State var videoFiles: [URL] = []
    @State var playerTreeNodes: [FileSystemTreeNode] = []
    
    func updatePlayerTreeNodes() {
        playerTreeNodes = FileSystemTreeBuilder.buildTree(rootURL: folderURL, files: videoFiles)
    }
    
    // MARK: - Tab 1: Player State
    @StateObject var playerEngine = PlayerEngine()
    @State var playerFilterText: String = ""
    @State var playerCollapsedFolderIDs: Set<String> = []
    @State var fileTagsMap: [URL: FinderTagColor] = [:]
    @State var showTagPickerPopover: Bool = false
    @State var queueScrollTarget: URL? = nil
    @State private var hasSetupKeyboardMonitor: Bool = false
    @State private var eventMonitors = EventMonitorCoordinator()
    
    // MARK: - Tab 2: Specs State
    @State var deliverableAssets: [DeliverableAsset] = []
    @State var specsFilterText: String = ""
    @State var selectedDeliverableURL: URL? = nil
    @State var isInspectingDeliverables: Bool = false
    @State var manifestCSVURL: URL? = nil
    @State var manifestHTMLURL: URL? = nil
    @State var deliverablesCollapsedFolderIDs: Set<String> = []
    @AppStorage("specsFileNameColumnWidth") var specsFileNameColumnWidth: Double = 220.0
    @State var liveFileNameColumnWidth: Double = 220.0
    @State var isDraggingFileNameColumn: Bool = false
    @State var dragStartFileNameWidth: Double? = nil
    @AppStorage("specsSortColumn") var specsSortColumnRaw: String = SpecsSortColumn.name.rawValue
    @AppStorage("specsSortAscending") var specsSortAscending: Bool = true
    
    var specsSortColumn: SpecsSortColumn {
        get { SpecsSortColumn(rawValue: specsSortColumnRaw) ?? .name }
        nonmutating set { specsSortColumnRaw = newValue.rawValue }
    }
    
    // MARK: - Tab 3: Line Finder State
    @State var hexCode: String = "#00FF00"
    @State var tolerancePercentage: Double = 25.0
    @State var edgeDepth: Int = 12
    @State var minSpanPercentage: Double = 70.0
    @State var scanFullScreen: Bool = false
    @State var enableExposureBoost: Bool = true
    @State var exposureMultiplier: Double = 10.0
    @State var ignoreFullBlackFrames: Bool = true
    @State var maxBlackVariance: Double = 2.0
    @State var enableHighlightExpansion: Bool = true
    @State var highlightMultiplier: Double = 8.0
    @State var ignoreFullWhiteFrames: Bool = true
    @State var maxWhiteVariance: Double = 2.0
    
    @State var isScanning: Bool = false
    @State var isAuditBtnHovered: Bool = false
    @State var progressInfo: VideoScanner.ScanProgress? = nil
    @State var scanResults: [VideoQCResult] = []
    @State var lastScanConfig: QCConfig? = nil
    @State var generatedReportURL: URL? = nil
    @State var generatedCSVURL: URL? = nil
    @State var scannerActor: VideoScanner? = nil
    
    // MARK: - Folder Grouping State
    @State var hideAllFolders: Bool = false
    @State var hiddenFolderIDs: Set<String> = []
    
    // MARK: - Toast Notification HUD State
    @State var toastMessage: String? = nil
    @State var toastDismissTask: Task<Void, Never>? = nil
    
    final class EventMonitorCoordinator {
        var mouseMonitor: Any? = nil
        var keyMonitor: Any? = nil
        
        deinit {
            cleanup()
        }
        
        func cleanup() {
            if let m = mouseMonitor {
                NSEvent.removeMonitor(m)
                mouseMonitor = nil
            }
            if let k = keyMonitor {
                NSEvent.removeMonitor(k)
                keyMonitor = nil
            }
        }
    }
    enum FullscreenMode: Equatable {
        case none
        case review
        case videoOnly
    }
    
    @State var fullscreenMode: FullscreenMode = .none
    var isFullscreenVideo: Bool { fullscreenMode != .none }
    @State var didToggleWindowForFullscreen: Bool = false
    
    var isTargetBlack: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    var isTargetWhite: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r >= 240 && rgb.g >= 240 && rgb.b >= 240
    }
    
    let colorPresets = [
        ("GREEN", "#00FF00", 25.0),
        ("MAGENTA", "#FF00B4", 25.0),
        ("BLACK", "#000000", 3.0),
        ("WHITE", "#FFFFFF", 3.0)
    ]
    
    var isCustomColor: Bool {
        !colorPresets.contains { $0.1.uppercased() == hexCode.uppercased() }
    }
    
    func openColorPanel() {
        NSColorPanel.setPickerMask(.wheelModeMask)
        NSColorPanel.setPickerMode(.wheel)
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let rgb = RGBColor(hex: hexCode) {
            panel.color = NSColor(srgbRed: CGFloat(rgb.r) / 255.0, green: CGFloat(rgb.g) / 255.0, blue: CGFloat(rgb.b) / 255.0, alpha: 1.0)
        }
        panel.isContinuous = true
        panel.orderFront(nil)
    }
    
    func colorFromHex(_ hex: String) -> Color {
        guard let rgb = RGBColor(hex: hex) else { return Color.clear }
        return Color(red: Double(rgb.r) / 255.0, green: Double(rgb.g) / 255.0, blue: Double(rgb.b) / 255.0)
    }
    
    // Dynamic Studio Theme Palette
    var bgMain: Color { StudioTheme.bgMain(isLightMode) }
    var bgPanel: Color { StudioTheme.bgPanel(isLightMode) }
    var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    var bgCardHeader: Color { StudioTheme.bgCardHeader(isLightMode) }
    var bgCardSubtle: Color { StudioTheme.bgCardSubtle(isLightMode) }
    var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    var borderStrong: Color { StudioTheme.borderStrong(isLightMode) }
    var textMain: Color { StudioTheme.textMain(isLightMode) }
    var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    var textSubtle: Color { StudioTheme.textSubtle(isLightMode) }
    var alertRed: Color { StudioTheme.negative }
    var accentPositive: Color { StudioTheme.positive }
    var accentNegative: Color { StudioTheme.negative }
    var accentSlotB: Color { StudioTheme.slotBAccent }
    var accentBlue: Color { StudioTheme.accentBlue(isLightMode) }
    var primaryBtnBg: Color { StudioTheme.primaryBtnBg(isLightMode) }
    var primaryBtnFg: Color { StudioTheme.primaryBtnFg(isLightMode) }
    
    var body: some View {
        ZStack {
            mainWorkspaceContent
            overlayModals
        }
        .preferredColorScheme(isLightMode ? .light : .dark)
        .animation(.easeInOut(duration: 0.15), value: showUserGuide)
        .animation(.easeInOut(duration: 0.15), value: showFeedbackModal)
        .animation(.easeInOut(duration: 0.15), value: showShortcutsModal)
        .animation(.easeInOut(duration: 0.15), value: showThemeModal)
        .animation(.easeInOut(duration: 0.15), value: showPropertiesModal)
        .animation(.easeInOut(duration: 0.15), value: showAddNoteModal)
        .animation(.easeInOut(duration: 0.15), value: showNotesDrawer)
        .animation(.easeInOut(duration: 0.15), value: fullscreenMode)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toastMessage)
        .onChange(of: showPropertiesModal) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
        .onChange(of: showAddNoteModal) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
        .onChange(of: playerEngine.activeURL) { _, newURL in
            loadNotesForActiveURL(newURL)
        }
        .onChange(of: showThemeModal) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
        .onChange(of: showUserGuide) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
        .onChange(of: showFeedbackModal) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
        .onChange(of: showShortcutsModal) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
        .onChange(of: updateManager.showModal) { _, newValue in
            if !newValue {
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(nil)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if fullscreenMode != .none {
                fullscreenMode = .none
                didToggleWindowForFullscreen = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            guard NSColorPanel.shared.isVisible else { return }
            if let srgb = NSColorPanel.shared.color.usingColorSpace(.sRGB) {
                let r = Int(round(srgb.redComponent * 255.0))
                let g = Int(round(srgb.greenComponent * 255.0))
                let b = Int(round(srgb.blueComponent * 255.0))
                let newHex = String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
                if hexCode.uppercased() != newHex {
                    hexCode = newHex
                }
            }
        }
        .onChange(of: hexCode) { _, newHex in
            if NSColorPanel.shared.isVisible, let rgb = RGBColor(hex: newHex) {
                let newColor = NSColor(srgbRed: CGFloat(rgb.r) / 255.0, green: CGFloat(rgb.g) / 255.0, blue: CGFloat(rgb.b) / 255.0, alpha: 1.0)
                if NSColorPanel.shared.color != newColor {
                    NSColorPanel.shared.color = newColor
                }
            }
        }
        .onChange(of: videoFiles) { _, _ in
            updatePlayerTreeNodes()
        }
        .onChange(of: folderURL) { _, _ in
            updatePlayerTreeNodes()
        }
        .onReceive(fileOpenManager.$pendingURLs) { urls in
            guard !urls.isEmpty else { return }
            handleIncomingOpenFiles(urls)
            fileOpenManager.pendingURLs = []
        }
        .onAppear {
            updatePlayerTreeNodes()
            setupKeyboardMonitor()
            loadFinderTagsForQueue()
            updateManager.checkForUpdates(userInitiated: false)
            if !fileOpenManager.pendingURLs.isEmpty {
                let urls = fileOpenManager.pendingURLs
                fileOpenManager.pendingURLs = []
                handleIncomingOpenFiles(urls)
            }
        }
        .onDisappear {
            eventMonitors.cleanup()
            hasSetupKeyboardMonitor = false
        }
    }
    
    // MARK: - Main Workspace Layout
    private var mainWorkspaceContent: some View {
        VStack(spacing: 0) {
            // 1. Dedicated Prominent Tab Navigation Bar with Right-Hand Controls
            tabBarStrip
            
            // 2. Main Tab Content
            switch selectedTab {
            case .player:
                playerTabView
            case .specs:
                deliverablesTabView
            case .lineFinder:
                lineScannerTabView
            }
            
            // 4. Bottom Contextual Explanation Bar
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            StudioStatusBarView(textMuted: textMuted, textMain: textMain)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(bgPanel)
        }
        .frame(minWidth: 1000, minHeight: 720)
        .background(bgMain)
        .foregroundColor(textMain)
    }
    
    // MARK: - Modal Overlays & Fullscreen Presentation
    @ViewBuilder
    private var overlayModals: some View {
        // In-App Operation Guide Overlay Modal
        if showUserGuide {
            UserGuideView(isPresented: $showUserGuide)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(100)
                .allowsHitTesting(showUserGuide)
        }
        
        // Feedback Form Overlay Modal
        if showFeedbackModal {
            FeedbackModalView(isPresented: $showFeedbackModal)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(150)
                .allowsHitTesting(showFeedbackModal)
        }
        
        // Keyboard Shortcuts Overlay Modal
        if showShortcutsModal {
            ShortcutsModalView(isPresented: $showShortcutsModal)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(155)
                .allowsHitTesting(showShortcutsModal)
        }
        
        // File Properties Overlay Modal (Premiere Pro Style)
        if showPropertiesModal {
            PropertiesModalView(
                isPresented: $showPropertiesModal,
                asset: propertiesAsset,
                fileURL: propertiesURL,
                isLoading: isInspectingProperties,
                isLightMode: isLightMode,
                onCopySpecs: { _ in
                    showToast("Specs copied to clipboard!")
                },
                onRevealInFinder: { url in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                onLoadSlotA: { url in
                    playerEngine.loadVideo(url: url, into: .slotA, autoplay: true)
                },
                onLoadSlotB: { url in
                    playerEngine.loadVideo(url: url, into: .slotB, autoplay: true)
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(156)
            .allowsHitTesting(showPropertiesModal)
        }
        
        // Theme & Accent Colors Overlay Modal
        if showThemeModal {
            ThemeSettingsModalView(isPresented: $showThemeModal)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(158)
                .allowsHitTesting(showThemeModal)
        }
        
        // Software Update Overlay Modal
        if updateManager.showModal {
            UpdateModalView(updateManager: updateManager, isPresented: $updateManager.showModal)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(160)
                .allowsHitTesting(updateManager.showModal)
        }
        
        // Dedicated Fullscreen Video Player Presentation
        if fullscreenMode == .review {
            fullscreenPlayerOverlay
                .transition(.opacity)
                .zIndex(200)
        } else if fullscreenMode == .videoOnly {
            cleanVideoFullscreenOverlay
                .transition(.opacity)
                .zIndex(200)
        }
        
        // Add Review Note Modal (Frame.io Style)
        if showAddNoteModal {
            AddNotePopoverView(
                isPresented: $showAddNoteModal,
                timecode: playerEngine.currentTimecode,
                frameIndex: playerEngine.currentFrame,
                isLightMode: isLightMode,
                onSave: { newNote in
                    addNote(newNote)
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(220)
            .allowsHitTesting(showAddNoteModal)
        }
        
        // Floating Notification Toast HUD
        if let toast = toastMessage {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(accentPositive)
                    Text(toast)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(bgPanel.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accentPositive.opacity(0.6), lineWidth: 1)
                )
                .cornerRadius(6)
                .shadow(color: Color.black.opacity(0.5), radius: 12, y: 6)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .zIndex(250)
            .allowsHitTesting(false)
        }
    }
    
    // MARK: - Navigation & Controls Bar
    
    private var topControls: some View {
        HStack(spacing: 8) {
            // Update Badge (if update available, keep prominent banner)
            if updateManager.hasUpdate {
                Button(action: { updateManager.showModal = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                        Text("UPDATE v\(updateManager.latestVersion)")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .studioBox(background: accentPositive, border: borderStrong)
                }
                .buttonStyle(.plain)
                .explain("New update v\(updateManager.latestVersion) available! Click to update.", binding: $hoverExplanation)
            }
            
            // Theme Toggle (Square button with Sun / Moon icon)
            Button(action: { isLightMode.toggle() }) {
                Image(systemName: isLightMode ? "sun.max.fill" : "moon.stars.fill")
                    .font(.system(size: StudioTheme.scaleFont(12), weight: .bold))
                    .frame(width: StudioTheme.scale(28), height: StudioTheme.scale(28))
                    .foregroundColor(textMain)
                    .studioBox(background: bgSubtle, border: borderLine)
            }
            .buttonStyle(.plain)
            .explain("Switch to \(isLightMode ? "Dark" : "Light") mode (T). ⇧T cycles accent theme.", binding: $hoverExplanation)
            
            // Settings Menu Button (Clean square gear button with zero chevron)
            Button(action: { showSettingsPopover.toggle() }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: StudioTheme.scaleFont(12), weight: .bold))
                        .frame(width: StudioTheme.scale(28), height: StudioTheme.scale(28))
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    
                    if updateManager.hasUpdate {
                        Circle()
                            .fill(accentPositive)
                            .frame(width: StudioTheme.scale(6), height: StudioTheme.scale(6))
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .explain("Settings: Software Update, Theme, Shortcuts, Info & Guide, and Feedback.", binding: $hoverExplanation)
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        showSettingsPopover = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            updateManager.checkForUpdates(userInitiated: true)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: updateManager.hasUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(updateManager.hasUpdate ? accentPositive : textMain)
                                .frame(width: 16)
                            Text(updateManager.hasUpdate ? "Software Update (v\(updateManager.latestVersion) available)" : "Software Update (v\(AppVersionInfo.version))")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(updateManager.hasUpdate ? accentPositive : textMain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Rectangle().fill(borderLine).frame(height: 1)
                    
                    Button(action: {
                        showSettingsPopover = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showThemeModal = true
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(themeManager.currentTheme.blueColor)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Theme & Accents")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                Text(themeManager.currentTheme.name)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(themeManager.currentTheme.blueColor)
                                    .lineLimit(1)
                            }
                            Spacer()
                            HStack(spacing: 3) {
                                Circle().fill(themeManager.currentTheme.greenColor).frame(width: 5, height: 5)
                                Circle().fill(themeManager.currentTheme.blueColor).frame(width: 5, height: 5)
                                Circle().fill(themeManager.currentTheme.purpleColor).frame(width: 5, height: 5)
                                Circle().fill(themeManager.currentTheme.redColor).frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Rectangle().fill(borderLine).frame(height: 1)
                    
                    Button(action: {
                        showSettingsPopover = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showUserGuide = true
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(textMain)
                                .frame(width: 16)
                            Text("Info / Guide")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Rectangle().fill(borderLine).frame(height: 1)
                    
                    Button(action: {
                        showSettingsPopover = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showFeedbackModal = true
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(textMain)
                                .frame(width: 16)
                            Text("Feedback & Support")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .frame(width: 250)
                .background(bgPanel)
            }
        }
    }

    
    // MARK: - Custom Tab Shapes for Seamless Body Blending
    struct OpenBottomTabBorderShape: Shape {
        var cornerRadius: CGFloat = 5
        
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
            path.addArc(
                center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
            path.addArc(
                center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        }
    }

    struct OpenBottomTabFillShape: Shape {
        var cornerRadius: CGFloat = 5
        var bleedBottom: CGFloat = 1.0
        
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY + bleedBottom))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
            path.addArc(
                center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
            path.addArc(
                center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + bleedBottom))
            path.closeSubpath()
            return path
        }
    }

    private let tabLength: CGFloat = 132
    
    private var tabBarStrip: some View {
        ZStack(alignment: .bottom) {
            // Baseline 1px divider spanning full width
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            HStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(AppTab.allCases) { tab in
                        let isActive = (selectedTab == tab)
                        let isHovered = (hoveredTab == tab)
                        
                        Button(action: {
                            selectedTab = tab
                            if tab == .specs && deliverableAssets.isEmpty && !videoFiles.isEmpty {
                                inspectDeliverablesBatch(urls: videoFiles)
                            } else if tab == .player && playerEngine.activeURL == nil, let first = videoFiles.first {
                                playerEngine.loadVideo(url: first)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: StudioTheme.scaleFont(11), weight: isActive ? .bold : .medium))
                                
                                Text(tab.title)
                                    .font(.system(size: StudioTheme.scaleFont(11), weight: isActive ? .bold : .medium, design: .monospaced))
                                    .tracking(0.5)
                                    .lineLimit(1)
                            }
                            .frame(width: tabLength * StudioTheme.buttonScale, height: StudioTheme.scale(29))
                            .foregroundColor(
                                isActive
                                    ? (isLightMode ? Color.black : Color.white)
                                    : (isHovered ? textMain : textMuted.opacity(0.72))
                            )
                            .background(
                                Group {
                                    if isActive {
                                        OpenBottomTabFillShape(cornerRadius: 5, bleedBottom: 1.0)
                                            .fill(bgPanel)
                                    } else {
                                        UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 5)
                                            .fill(isHovered ? bgSubtle.opacity(isLightMode ? 0.85 : 0.55) : bgSubtle.opacity(isLightMode ? 0.4 : 0.22))
                                    }
                                }
                            )
                            .overlay(
                                Group {
                                    if isActive {
                                        OpenBottomTabBorderShape(cornerRadius: 5)
                                            .stroke(isLightMode ? borderStrong : Color(white: 0.32), lineWidth: 1)
                                    } else {
                                        UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 5)
                                            .stroke(
                                                isHovered ? borderLine : borderLine.opacity(isLightMode ? 0.45 : 0.25),
                                                lineWidth: 1
                                            )
                                    }
                                }
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.12)) {
                                if hovering {
                                    hoveredTab = tab
                                } else if hoveredTab == tab {
                                    hoveredTab = nil
                                }
                            }
                        }
                        .explain(
                            tab == .player ? "PLAYER: High-performance delivery playback with J-K-L shuttle, timeline scrubbing, and zoom." :
                            (tab == .specs ? "SPECS: Reads container resolution, timecode, audio, and codecs." :
                             "LINE FINDER: Scans video frames for edge line glitches and blanking errors."),
                            binding: $hoverExplanation
                        )
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                
                Spacer()
                
                topControls
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: StudioTheme.scale(42))
    }
    
    // MARK: - Reusable Unified Asset Selection Section
    
    func deliveryAssetsSection(forTab: AppTab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "01", title: "LOAD ASSETS")
            
            VStack(alignment: .leading, spacing: 8) {
                // Action Toolbar: SELECT/CHANGE, ADD, HIDE/SHOW, plus trailing Asset Count
                HStack(spacing: 5) {
                    let isSelectEmpty = (folderURL == nil && videoFiles.isEmpty)
                    Button(action: { selectAssets(forTab: forTab, append: false) }) {
                        HStack(spacing: 4) {
                            Image(systemName: isSelectEmpty ? "folder.badge.plus" : "arrow.triangle.2.circlepath")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text(isSelectEmpty ? "SELECT" : "CHANGE")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: StudioTheme.scale(24))
                        .foregroundColor(isSelectEmpty ? accentBlue : textMain)
                        .studioBox(
                            background: isSelectEmpty ? accentBlue.opacity(0.12) : bgSubtle,
                            border: isSelectEmpty ? accentBlue.opacity(0.4) : borderLine
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .explain(isSelectEmpty ? "Opens file picker to select video files or a folder to inspect." : "Replaces currently loaded assets with a new folder or file selection.", binding: $hoverExplanation)
                    
                    Button(action: { selectAssets(forTab: forTab, append: true) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text("ADD")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: StudioTheme.scale(24))
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .explain("Opens file picker to add more video files or folders to current list without losing existing assets.", binding: $hoverExplanation)
                    
                    let canRefresh = (folderURL != nil || !videoFiles.isEmpty)
                    Button(action: { refreshPlayerAssets() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text("REFRESH")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: StudioTheme.scale(24))
                        .foregroundColor(canRefresh ? textMain : textSubtle)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning || !canRefresh)
                    .explain("Rescans loaded folders and files to detect added, removed, or modified videos.", binding: $hoverExplanation)
                    
                    Spacer(minLength: 4)
                    
                    if !videoFiles.isEmpty {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(accentPositive)
                                .frame(width: StudioTheme.scale(5), height: StudioTheme.scale(5))
                            Text("\(videoFiles.count) \(videoFiles.count == 1 ? "FILE" : "FILES")")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: StudioTheme.scale(24))
                        .studioBox(background: bgSubtle.opacity(0.4), border: borderLine.opacity(0.6))
                    }
                }
                
                if let folder = folderURL {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.lastPathComponent.uppercased())
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                        Text("\(videoFiles.count) ASSET(S) FOUND IN DIRECTORY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioBox(background: bgCardSubtle, border: borderLine)
                    .contentShape(Rectangle())
                    .explain(folder.path, binding: $hoverExplanation)
                    .contextMenu {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(folder.path, forType: .string)
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                } else if !videoFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if videoFiles.count == 1, let first = videoFiles.first {
                            Text(first.lastPathComponent.uppercased())
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .foregroundColor(textMain)
                                .lineLimit(1)
                            Text("1 ASSET LOADED DIRECTLY")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                        } else {
                            Text("\(videoFiles.count) INDIVIDUAL FILE(S)")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .foregroundColor(textMain)
                            Text("BATCH LOADED DIRECTLY")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioBox(background: bgCardSubtle, border: borderLine)
                    .contentShape(Rectangle())
                    .explain(videoFiles.count == 1 ? (videoFiles.first?.path ?? "") : (videoFiles.first?.deletingLastPathComponent().path ?? ""), binding: $hoverExplanation)
                    .contextMenu {
                        if videoFiles.count == 1, let first = videoFiles.first {
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(first.path, forType: .string)
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([first])
                            }
                        } else {
                            Button("Copy All Paths") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(videoFiles.map { $0.path }.joined(separator: "\n"), forType: .string)
                            }
                            if let first = videoFiles.first {
                                Button("Copy Path (First File)") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(first.path, forType: .string)
                                }
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(videoFiles)
                            }
                        }
                    }
                } else {
                    Text("DRAG & DROP FOLDER OR VIDEO FILES HERE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                        .studioBox(background: bgCardSubtle, border: borderLine)
                        .explain("Drag and drop video files or folders directly into the app.", binding: $hoverExplanation)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers, forTab: forTab)
        }
    }
    
    // MARK: - Folder Grouping Helpers
    
    func toggleHideFolders() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if hideAllFolders || !hiddenFolderIDs.isEmpty {
                hideAllFolders = false
                hiddenFolderIDs.removeAll()
            } else {
                hideAllFolders = true
            }
        }
    }
    
    func hideSpecificFolder(id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = hiddenFolderIDs.insert(id)
        }
    }
    
    func clearFolder(node: FileSystemTreeNode) {
        let urlsToRemove = Set(node.videoURLs.map { $0.standardizedFileURL.path })
        withAnimation(.easeInOut(duration: 0.2)) {
            videoFiles.removeAll { urlsToRemove.contains($0.standardizedFileURL.path) }
            deliverableAssets.removeAll { urlsToRemove.contains($0.fileURL.standardizedFileURL.path) }
            scanResults.removeAll { urlsToRemove.contains($0.fileURL.standardizedFileURL.path) }
            
            func collectFolderIDs(_ n: FileSystemTreeNode) -> [String] {
                var ids = [n.id]
                for child in n.children where child.isDirectory {
                    ids.append(contentsOf: collectFolderIDs(child))
                }
                return ids
            }
            let allFolderIDs = Set(collectFolderIDs(node))
            playerCollapsedFolderIDs.subtract(allFolderIDs)
            deliverablesCollapsedFolderIDs.subtract(allFolderIDs)
            hiddenFolderIDs.subtract(allFolderIDs)
            
            if videoFiles.isEmpty {
                folderURL = nil
            } else {
                folderURL = determineFolderURL(for: videoFiles, detectedFolder: folderURL)
            }
            
            FileSystemTreeBuilder.clearCache()
            updatePlayerTreeNodes()
            
            if let active = playerEngine.activeURL, urlsToRemove.contains(active.standardizedFileURL.path) {
                if let next = videoFiles.first {
                    playerEngine.loadVideo(url: next)
                } else {
                    playerEngine.unload()
                }
            }
            if let slotB = playerEngine.slotB.url, urlsToRemove.contains(slotB.standardizedFileURL.path) {
                playerEngine.clearSlotB()
            }
        }
    }
    
    // MARK: - Asset Selection & Drop Handlers
    
    func determineFolderURL(for videos: [URL], detectedFolder: URL?) -> URL? {
        if let folder = detectedFolder {
            let folderPath = folder.standardizedFileURL.path
            let allInside = videos.allSatisfy { $0.standardizedFileURL.path.hasPrefix(folderPath) }
            if allInside { return folder }
        }
        guard !videos.isEmpty else { return nil }
        var common = videos[0].deletingLastPathComponent().standardizedFileURL
        for v in videos.dropFirst() {
            let parent = v.deletingLastPathComponent().standardizedFileURL
            while !parent.path.hasPrefix(common.path) && common.path != "/" {
                common = common.deletingLastPathComponent()
            }
        }
        if common.path == "/" || common.path == "/Users" || common.path == "/Volumes" {
            return nil
        }
        return common
    }
    
    func selectAssets(forTab: AppTab, append: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType.quickTimeMovie, UTType.mpeg4Movie, UTType.folder]
        panel.prompt = append ? "Add" : "Select"
        panel.message = append ? "Choose video files or folders to add to the current batch" : "Choose video files or a folder to load"
        
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            var collectedVideos: [URL] = []
            var detectedFolder: URL? = nil
            
            for url in panel.urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        detectedFolder = url
                        let inFolder = VideoScanner.findVideoFiles(in: url)
                        collectedVideos.append(contentsOf: inFolder)
                    } else {
                        if detectedFolder == nil {
                            detectedFolder = url.deletingLastPathComponent()
                        }
                        if QCUtilities.isSupportedVideo(url: url) {
                            collectedVideos.append(url)
                        }
                    }
                }
            }
            
            if append {
                var mergedVideos = self.videoFiles
                var seen = Set(self.videoFiles.map { $0.standardizedFileURL.path })
                var newlyAdded: [URL] = []
                
                for v in collectedVideos {
                    let stdPath = v.standardizedFileURL.path
                    if !seen.contains(stdPath) {
                        seen.insert(stdPath)
                        mergedVideos.append(v)
                        newlyAdded.append(v)
                    }
                }
                
                guard !newlyAdded.isEmpty else { return }
                
                self.videoFiles = mergedVideos
                self.folderURL = determineFolderURL(for: mergedVideos, detectedFolder: self.folderURL ?? detectedFolder)
                
                // Inspect only newly added deliverables and append to existing deliverables
                inspectDeliverablesBatch(urls: newlyAdded, append: true)
                self.loadFinderTagsForQueue()
                if self.playerEngine.activeURL == nil, let first = newlyAdded.first {
                    self.playerEngine.loadVideo(url: first)
                }
            } else {
                var uniqueVideos: [URL] = []
                var seen: Set<String> = []
                for v in collectedVideos {
                    let stdPath = v.standardizedFileURL.path
                    if !seen.contains(stdPath) {
                        seen.insert(stdPath)
                        uniqueVideos.append(v)
                    }
                }
                
                guard !uniqueVideos.isEmpty else { return }
                
                self.folderURL = determineFolderURL(for: uniqueVideos, detectedFolder: detectedFolder)
                self.videoFiles = uniqueVideos
                self.playerCollapsedFolderIDs = []
                self.deliverablesCollapsedFolderIDs = []
                self.scanResults = []
                self.generatedReportURL = nil
                self.generatedCSVURL = nil
                
                // Populate deliverables in background
                inspectDeliverablesBatch(urls: uniqueVideos, append: false)
                self.loadFinderTagsForQueue()
                if self.playerEngine.activeURL == nil, let first = uniqueVideos.first {
                    self.playerEngine.loadVideo(url: first)
                }
            }
        }
    }
    
    func handleDrop(providers: [NSItemProvider], forTab: AppTab, targetSlot: SlotTarget? = nil) -> Bool {
        guard !providers.isEmpty else { return false }
        
        final class URLCollector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var urls: [URL] = []
            
            func append(_ url: URL) {
                lock.lock()
                defer { lock.unlock() }
                urls.append(url)
            }
        }
        
        let collector = URLCollector()
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    collector.append(url)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            self.addAssets(urls: collector.urls, targetSlot: targetSlot)
        }
        return true
    }
    
    func handleIncomingOpenFiles(_ urls: [URL]) {
        self.selectedTab = .player
        self.addAssets(urls: urls, forceLoad: true)
    }
    
    func addAssets(urls: [URL], targetSlot: SlotTarget? = nil, forceLoad: Bool = false) {
        guard !urls.isEmpty else { return }
        var collectedVideos: [URL] = []
        var detectedFolder: URL? = nil
        
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if detectedFolder == nil {
                        detectedFolder = url
                    }
                    let inFolder = VideoScanner.findVideoFiles(in: url)
                    collectedVideos.append(contentsOf: inFolder)
                } else {
                    if detectedFolder == nil {
                        detectedFolder = url.deletingLastPathComponent()
                    }
                    if QCUtilities.isSupportedVideo(url: url) {
                        collectedVideos.append(url)
                    }
                }
            }
        }
        
        guard !collectedVideos.isEmpty else { return }
        
        var mergedVideos = self.videoFiles
        var seen = Set(self.videoFiles.map { $0.standardizedFileURL.path })
        var newlyAdded: [URL] = []
        
        for v in collectedVideos {
            let stdPath = v.standardizedFileURL.path
            if !seen.contains(stdPath) {
                seen.insert(stdPath)
                mergedVideos.append(v)
                newlyAdded.append(v)
            }
        }
        
        if !newlyAdded.isEmpty {
            self.videoFiles = mergedVideos
            self.folderURL = self.determineFolderURL(for: mergedVideos, detectedFolder: self.folderURL ?? detectedFolder)
            self.inspectDeliverablesBatch(urls: newlyAdded, append: true)
            self.loadFinderTagsForQueue()
        }
        
        if let targetSlot = targetSlot {
            if let targetURL = newlyAdded.first ?? collectedVideos.first {
                self.playerEngine.loadVideo(url: targetURL, into: targetSlot)
            }
        } else if forceLoad {
            if let first = newlyAdded.first ?? collectedVideos.first {
                self.playerEngine.loadVideo(url: first, into: .slotA, autoplay: self.playerEngine.isAutoplayEnabled)
                self.queueScrollTarget = first
            }
        } else if self.playerEngine.activeURL == nil, let first = newlyAdded.first ?? collectedVideos.first {
            self.playerEngine.loadVideo(url: first)
            self.queueScrollTarget = first
        }
    }
    
    // MARK: - Line Scanner Execution
    
    func startScan() {
        guard !videoFiles.isEmpty else { return }
        
        let config = QCConfig(
            targetHex: hexCode,
            tolerance: tolerancePercentage / 100.0,
            edgeDepth: edgeDepth,
            minSpanRatio: minSpanPercentage / 100.0,
            scanFullScreen: scanFullScreen,
            enableExposureBoost: enableExposureBoost,
            exposureMultiplier: exposureMultiplier,
            ignoreFullBlackFrames: ignoreFullBlackFrames,
            maxBlackVariance: maxBlackVariance,
            enableHighlightExpansion: enableHighlightExpansion,
            highlightMultiplier: highlightMultiplier,
            ignoreFullWhiteFrames: ignoreFullWhiteFrames,
            maxWhiteVariance: maxWhiteVariance
        )
        
        isScanning = true
        scanResults = []
        generatedReportURL = nil
        generatedCSVURL = nil
        
        let scanner = VideoScanner()
        self.scannerActor = scanner
        
        Task {
            let results = await scanner.scanBatch(videoURLs: videoFiles, config: config, maxConcurrentScanners: 2) { progress in
                DispatchQueue.main.async {
                    self.progressInfo = progress
                }
            }
            
            // Only tag flagged files in Finder — no auto file export
            ReportWriter.tagFlaggedFilesInFinder(results: results)
            
            DispatchQueue.main.async {
                self.scanResults = results
                self.lastScanConfig = config
                self.playerEngine.setScanResults(results)
                for res in results where res.isFlagged {
                    self.fileTagsMap[res.fileURL] = .red
                }
                self.syncScanResultsToNotes(results: results)
                self.isScanning = false
                self.scannerActor = nil
            }
        }
    }
    
    func cancelScan() {
        scannerActor?.cancel()
        self.isScanning = false
        self.scannerActor = nil
    }
    
    // MARK: - On-Demand Report Export
    
    func exportScanHTML() {
        guard !scanResults.isEmpty, let config = lastScanConfig else { return }
        let folder = folderURL ?? videoFiles.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        
        let csvFileName = "QC_Report.csv"
        let htmlString = ReportWriter.generateHTMLReport(folderURL: folder, config: config, results: scanResults, csvFileName: csvFileName)
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.nameFieldStringValue = "QC_Report_\(folder.lastPathComponent).html"
        savePanel.directoryURL = folder
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? htmlString.write(to: url, atomically: true, encoding: .utf8)
            self.generatedReportURL = url
            NSWorkspace.shared.open(url)
        }
    }
    
    func exportScanCSV() {
        guard !scanResults.isEmpty else { return }
        let folder = folderURL ?? videoFiles.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        
        let csvString = ReportWriter.generateCSVReport(results: scanResults)
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "QC_Report_\(folder.lastPathComponent).csv"
        savePanel.directoryURL = folder
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csvString.write(to: url, atomically: true, encoding: .utf8)
            self.generatedCSVURL = url
            NSWorkspace.shared.open(url)
        }
    }
    
    func openScanReportInGoogleSheets() {
        guard !scanResults.isEmpty else { return }
        let tsvString = ReportWriter.generateTSVReport(results: scanResults)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tsvString, forType: .string)
        
        if let url = URL(string: "https://sheets.new") {
            NSWorkspace.shared.open(url)
        }
        showToast("Scan report copied! Press ⌘V in Google Sheets.")
    }
    
    // MARK: - Player Queue Refresh
    
    func refreshPlayerAssets() {
        guard !videoFiles.isEmpty || folderURL != nil else { return }
        
        var refreshedVideos: [URL] = []
        var seen = Set<String>()
        
        // 1. If we have a root folderURL, re-scan it
        if let folder = folderURL, FileManager.default.fileExists(atPath: folder.path) {
            let found = VideoScanner.findVideoFiles(in: folder)
            for v in found {
                let std = v.standardizedFileURL.path
                if !seen.contains(std) {
                    seen.insert(std)
                    refreshedVideos.append(v)
                }
            }
        }
        
        // 2. Also check any root folders in playerTreeNodes (handles multiple dropped/added folders)
        for node in playerTreeNodes where node.isDirectory {
            if FileManager.default.fileExists(atPath: node.url.path) {
                let found = VideoScanner.findVideoFiles(in: node.url)
                for v in found {
                    let std = v.standardizedFileURL.path
                    if !seen.contains(std) {
                        seen.insert(std)
                        refreshedVideos.append(v)
                    }
                }
            }
        }
        
        // 3. Keep any standalone files that still exist on disk
        for v in videoFiles {
            let std = v.standardizedFileURL.path
            if !seen.contains(std) && FileManager.default.fileExists(atPath: v.path) {
                seen.insert(std)
                refreshedVideos.append(v)
            }
        }
        
        self.videoFiles = refreshedVideos
        self.folderURL = determineFolderURL(for: refreshedVideos, detectedFolder: self.folderURL)
        self.updatePlayerTreeNodes()
        self.loadFinderTagsForQueue()
        
        // Sync with Deliverables inspector if deliverables are loaded
        if !deliverableAssets.isEmpty {
            inspectDeliverablesBatch(urls: refreshedVideos, append: false)
        }
        
        // Validate active slot videos
        if let active = playerEngine.activeURL, !FileManager.default.fileExists(atPath: active.path) {
            if let first = refreshedVideos.first {
                playerEngine.loadVideo(url: first)
            } else {
                playerEngine.unload()
            }
        } else if playerEngine.activeURL == nil, let first = refreshedVideos.first {
            playerEngine.loadVideo(url: first)
        }
        
        if let slotB = playerEngine.slotB.url, !FileManager.default.fileExists(atPath: slotB.path) {
            playerEngine.clearSlotB()
        }
        
        showToast("Queue refreshed (\(refreshedVideos.count) \(refreshedVideos.count == 1 ? "file" : "files"))")
    }
    
    // MARK: - Deliverables Specs Execution
    
    func rescanDeliverables() {
        if let folder = folderURL {
            let inFolder = VideoScanner.findVideoFiles(in: folder)
            var merged = inFolder
            var seen = Set(inFolder.map { $0.standardizedFileURL.path })
            for v in videoFiles {
                let std = v.standardizedFileURL.path
                if !seen.contains(std) && FileManager.default.fileExists(atPath: v.path) {
                    seen.insert(std)
                    merged.append(v)
                }
            }
            self.videoFiles = merged
            inspectDeliverablesBatch(urls: merged, append: false)
        } else if !videoFiles.isEmpty {
            let valid = videoFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
            self.videoFiles = valid
            inspectDeliverablesBatch(urls: valid, append: false)
        }
    }
    
    func inspectDeliverablesBatch(urls: [URL], append: Bool = false) {
        guard !urls.isEmpty else { return }
        isInspectingDeliverables = true
        
        Task {
            let assets = await DeliverablesInspector.inspectBatch(urls: urls)
            
            DispatchQueue.main.async {
                if append {
                    var existingMap = Dictionary(uniqueKeysWithValues: self.deliverableAssets.map { ($0.fileURL.standardizedFileURL, $0) })
                    for asset in assets {
                        let key = asset.fileURL.standardizedFileURL
                        if existingMap[key] == nil {
                            existingMap[key] = asset
                            self.deliverableAssets.append(asset)
                        }
                    }
                } else {
                    self.deliverableAssets = assets
                }
                self.isInspectingDeliverables = false
            }
        }
    }
    
    func playDeliverableInPlayer(url: URL) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            selectedTab = .player
        }
        playerEngine.loadVideo(url: url, into: .slotA, autoplay: true)
    }
    
    func exportDeliverablesManifest() {
        guard !deliverableAssets.isEmpty else { return }
        
        let csvString = DeliverablesInspector.generateManifestCSV(assets: deliverableAssets, rootFolderURL: folderURL)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        savePanel.nameFieldStringValue = "Deliverables_Specs_\(Date().timeIntervalSince1970).csv"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csvString.write(to: url, atomically: true, encoding: .utf8)
            self.manifestCSVURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    func openManifestHTML() {
        guard !deliverableAssets.isEmpty else { return }
        
        let folderName = (folderURL ?? deliverableAssets.first?.fileURL.deletingLastPathComponent())?.lastPathComponent ?? "DELIVERY_ASSETS"
        let htmlString = DeliverablesInspector.generateManifestHTML(assets: deliverableAssets, folderName: folderName, rootFolderURL: folderURL)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Deliverables_Specs_\(UUID().uuidString).html")
        
        do {
            try htmlString.write(to: tempURL, atomically: true, encoding: .utf8)
            self.manifestHTMLURL = tempURL
            NSWorkspace.shared.open(tempURL)
        } catch {
            print("Failed to open Deliverables HTML: \(error)")
        }
    }
    
    func openDeliverablesInGoogleSheets() {
        guard !deliverableAssets.isEmpty else { return }
        let tsvString = DeliverablesInspector.generateManifestTSV(assets: deliverableAssets, rootFolderURL: folderURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tsvString, forType: .string)
        
        if let url = URL(string: "https://sheets.new") {
            NSWorkspace.shared.open(url)
        }
        showToast("Specs copied! Press ⌘V in Google Sheets.")
    }
    
    func showToast(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            self.toastMessage = message
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.toastMessage = nil
            }
        }
    }
    
    // MARK: - Reusable UI Subviews & Helpers
    
    func sectionHeader(num: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(num)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMain)
            Text("// \(title)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .tracking(1.0)
        }
    }
    
    func statBox(title: String, val: String, isRed: Bool = false, isPositive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
            Text(val)
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(isRed ? alertRed : (isPositive ? accentPositive : textMain))
        }
        .padding(.trailing, 16)
        .padding(.vertical, 4)
    }
    
    func statItem(label: String, val: String, width: CGFloat? = nil, isAlert: Bool = false, isPositive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .lineLimit(1)
            Text(val)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(isAlert ? alertRed : (isPositive ? accentPositive : textMain))
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
    
    func formatTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(textSubtle)
            .studioBox(background: bgSubtle, border: borderLine)
    }
    
    // MARK: - Fullscreen Player Controls
    
    func enterFullscreen(mode: FullscreenMode = .videoOnly) {
        guard playerEngine.activeURL != nil else { return }
        fullscreenMode = mode
        playerEngine.setZoomFit()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            if !window.styleMask.contains(.fullScreen) {
                didToggleWindowForFullscreen = true
                window.toggleFullScreen(nil)
            } else {
                didToggleWindowForFullscreen = false
            }
        }
    }
    
    func exitFullscreen() {
        fullscreenMode = .none
        if didToggleWindowForFullscreen {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }),
               window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            didToggleWindowForFullscreen = false
        }
    }
    
    // MARK: - Global Player Keyboard Shortcuts (J-K-L, Space, Arrows, F, ESC)
    
    func setupKeyboardMonitor() {
        guard !hasSetupKeyboardMonitor else { return }
        hasSetupKeyboardMonitor = true
        
        eventMonitors.cleanup()
        
        // Click-away monitor: dismisses text field focus when clicking anywhere outside text inputs
        eventMonitors.mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = NSApp.keyWindow,
               let firstResponder = window.firstResponder,
               firstResponder is NSTextView {
                let clickLoc = event.locationInWindow
                if let hitView = window.contentView?.hitTest(clickLoc) {
                    var isTextInput = false
                    var curr: NSView? = hitView
                    while let v = curr {
                        if v is NSTextField || v is NSTextView {
                            isTextInput = true
                            break
                        }
                        curr = v.superview
                    }
                    if !isTextInput {
                        window.makeFirstResponder(nil)
                    }
                }
            }
            return event
        }
        
        eventMonitors.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check if user is typing in a text field
            if let window = NSApp.keyWindow,
               let firstResponder = window.firstResponder,
               firstResponder is NSTextView {
                if event.keyCode == 53 { // ESC key: dismiss search filter focus immediately
                    window.makeFirstResponder(nil)
                    return nil
                }
                if event.keyCode == 36 { // Return key: commit and dismiss search filter focus
                    window.makeFirstResponder(nil)
                    return nil
                }
                return event
            }
            
            // ESC key: Dismiss any active modal or exit fullscreen
            if event.keyCode == 53 {
                if self.showPropertiesModal {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.showPropertiesModal = false
                    }
                    return nil
                }
                if self.showAddNoteModal {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.showAddNoteModal = false
                    }
                    return nil
                }
                if self.showNotesDrawer {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.showNotesDrawer = false
                    }
                    return nil
                }
                if self.showThemeModal {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.showThemeModal = false
                    }
                    return nil
                }
                if self.showShortcutsModal {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.showShortcutsModal = false
                    }
                    return nil
                }
                if self.showUserGuide {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.showUserGuide = false
                    }
                    return nil
                }
                if self.showFeedbackModal {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.showFeedbackModal = false
                    }
                    return nil
                }
                if self.updateManager.showModal {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.updateManager.showModal = false
                    }
                    return nil
                }
                if self.fullscreenMode != .none {
                    self.exitFullscreen()
                    return nil
                }
            }
            
            let isShift = event.modifierFlags.contains(.shift)
            let isCommand = event.modifierFlags.contains(.command)
            let isControl = event.modifierFlags.contains(.control)
            let isOption = event.modifierFlags.contains(.option)
            let rawChars = event.charactersIgnoringModifiers?.lowercased()
            
            // Global UI Button Zoom Shortcuts: Cmd + / Cmd = (Zoom In), Cmd - (Zoom Out)
            if isCommand && !isControl && !isOption {
                let isPlus = (event.keyCode == 24 || event.keyCode == 69 || rawChars == "=" || rawChars == "+" || event.characters == "+")
                let isMinus = (event.keyCode == 27 || event.keyCode == 78 || rawChars == "-" || rawChars == "_" || event.characters == "-")
                
                if isPlus {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        _ = self.themeManager.increaseButtonZoom()
                    }
                    self.showToast("BUTTON SIZE: \(self.themeManager.buttonZoom.title) (\(String(format: "%.1fx", self.themeManager.buttonZoom.scaleFactor)))")
                    return nil
                } else if isMinus {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        _ = self.themeManager.decreaseButtonZoom()
                    }
                    self.showToast("BUTTON SIZE: \(self.themeManager.buttonZoom.title) (\(String(format: "%.1fx", self.themeManager.buttonZoom.scaleFactor)))")
                    return nil
                }
            }
            
            // If any modal is active, block background player controls
            if self.showShortcutsModal || self.showThemeModal || self.showUserGuide || self.showFeedbackModal || self.updateManager.showModal || self.showPropertiesModal || self.showAddNoteModal {
                return event
            }
            
            // 1. Global Tab Switching Shortcuts: Shift + 1, Shift + 2, Shift + 3
            if isShift && !isCommand && !isControl && !isOption {
                if event.keyCode == 18 || rawChars == "1" || event.characters == "!" {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        self.selectedTab = .player
                    }
                    return nil
                } else if event.keyCode == 19 || rawChars == "2" || event.characters == "@" {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        self.selectedTab = .specs
                    }
                    if self.deliverableAssets.isEmpty && !self.videoFiles.isEmpty {
                        self.inspectDeliverablesBatch(urls: self.videoFiles)
                    }
                    return nil
                } else if event.keyCode == 20 || rawChars == "3" || event.characters == "#" {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        self.selectedTab = .lineFinder
                    }
                    return nil
                }
            }
            
            // 2. Global Theme Shortcuts:
            // T: Switch light / dark mode
            // Shift + T: Cycle accent palette
            if !isCommand && !isControl && !isOption && (event.keyCode == 17 || rawChars == "t") {
                if isShift {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        ThemeManager.shared.cycleAccentTheme()
                    }
                    return nil
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.isLightMode.toggle()
                    }
                    return nil
                }
            }
            
            // Finder Color Tags (Player tab & Specs tab): 1 = Red, 2 = Green, 3 = Blue, 4 = Yellow, 5 = Orange, 6 = Purple, 7 = Gray (0 = Clear)
            if (self.selectedTab == .player || self.selectedTab == .specs) && !isShift && !isCommand && !isControl && !isOption {
                let tagForNum: FinderTagColor?
                switch event.keyCode {
                case 18: tagForNum = .red      // 1: Red
                case 19: tagForNum = .green    // 2: Green
                case 20: tagForNum = .blue     // 3: Blue
                case 21: tagForNum = .yellow   // 4: Yellow
                case 23: tagForNum = .orange   // 5: Orange
                case 22: tagForNum = .purple   // 6: Purple
                case 26: tagForNum = .gray     // 7: Gray
                default:
                    if rawChars == "1" { tagForNum = .red }
                    else if rawChars == "2" { tagForNum = .green }
                    else if rawChars == "3" { tagForNum = .blue }
                    else if rawChars == "4" { tagForNum = .yellow }
                    else if rawChars == "5" { tagForNum = .orange }
                    else if rawChars == "6" { tagForNum = .purple }
                    else if rawChars == "7" { tagForNum = .gray }
                    else { tagForNum = nil }
                }
                
                let targetURL: URL?
                if self.selectedTab == .player {
                    let currentTarget = self.playerEngine.activeTarget
                    targetURL = (currentTarget == .slotB && self.playerEngine.slotB.url != nil) ? self.playerEngine.slotB.url : self.playerEngine.activeURL
                } else {
                    targetURL = self.selectedDeliverableURL ?? self.deliverableAssets.first?.fileURL
                }
                
                if event.keyCode == 29 || rawChars == "0" { // 0: Remove Tag
                    if let targetURL = targetURL {
                        self.setFinderTag(nil, for: targetURL)
                        return nil
                    }
                } else if let tag = tagForNum {
                    if let targetURL = targetURL {
                        self.toggleFinderTag(tag, for: targetURL)
                        return nil
                    }
                }
            }
            
            // Player-specific shortcuts below this point
            guard self.selectedTab == .player else { return event }
            
            // J K L Shuttle & Core Player Keys
            if let chars = rawChars {
                if chars == "j" && !isCommand && !isControl {
                    if isShift {
                        self.playerEngine.pressSlowJ()
                    } else {
                        self.playerEngine.pressJ()
                    }
                    return nil
                } else if chars == "k" && !isCommand && !isControl {
                    self.playerEngine.pressK()
                    return nil
                } else if chars == "l" && !isCommand && !isControl {
                    if isShift {
                        self.playerEngine.pressSlowL()
                    } else {
                        self.playerEngine.pressL()
                    }
                    return nil
                } else if chars == "l" && isCommand {
                    self.playerEngine.isLooping.toggle()
                    return nil
                } else if chars == "a" && !isCommand && !isControl && !isShift && !isOption { // A: Toggle Autoplay ON/OFF
                    self.playerEngine.isAutoplayEnabled.toggle()
                    return nil
                } else if chars == " " { // Spacebar
                    self.playerEngine.togglePlayPause()
                    return nil
                } else if chars == "f" && !isCommand && !isControl { // F: Toggle Video Fullscreen (Clean) / Shift+F: Review Fullscreen
                    if self.fullscreenMode != .none {
                        self.exitFullscreen()
                    } else if self.playerEngine.activeURL != nil {
                        self.enterFullscreen(mode: isShift ? .review : .videoOnly)
                    }
                    return nil
                } else if chars == "n" && !isCommand && !isControl && !isShift && !isOption { // N: Add Review Note at current frame
                    if self.playerEngine.activeURL != nil {
                        self.openAddNoteModal()
                        return nil
                    }
                } else if (chars == "]" || event.keyCode == 30) || (chars == "n" && isOption && !isShift) { // ]: Jump to Next Review Note
                    self.playerEngine.jumpToNextNote()
                    return nil
                } else if (chars == "[" || event.keyCode == 33) || (chars == "n" && isOption && isShift) { // [: Jump to Previous Review Note
                    self.playerEngine.jumpToPreviousNote()
                    return nil
                } else if chars == "m" && !isCommand && !isControl && !isOption { // M: Next Line Finding / Shift+M: Previous Line Finding
                    if isShift {
                        self.jumpToPreviousGlitchFinding()
                    } else {
                        self.jumpToNextGlitchFinding()
                    }
                    return nil
                } else if (chars == "s" || chars == "x") && !isCommand && !isControl && !isShift && !isOption { // S / X: Swap Slot A and Slot B
                    if self.playerEngine.slotB.url != nil {
                        self.playerEngine.swapSlots()
                        return nil
                    }
                } else if chars == "c" && !isCommand && !isControl { // C: Cycle compare modes
                    if self.playerEngine.slotB.url != nil {
                        self.playerEngine.cycleCompareMode()
                        return nil
                    }
                } else if chars == "?" || (isCommand && chars == "/") {
                    self.showUserGuide.toggle()
                    return nil
                } else if chars == "i" && !isCommand && !isControl && !isOption && !isShift { // I: Cycle clip info (Off -> A/B -> Resolution -> Name -> Full Details)
                    self.playerEngine.cycleClipInfoOverlayMode()
                    return nil
                } else if (chars == "i" && (isControl || isCommand)) || (chars == "p" && isCommand) {
                    self.togglePropertiesModalForActiveOrSelected()
                    return nil
                }
            }
            
            switch event.keyCode {
            case 0: // A key: Toggle Autoplay fallback
                if !isCommand && !isControl && !isShift && !isOption {
                    self.playerEngine.isAutoplayEnabled.toggle()
                    return nil
                }
            case 34: // I key: Fallback for cycling clip info
                if !isCommand && !isControl && !isOption && !isShift {
                    self.playerEngine.cycleClipInfoOverlayMode()
                    return nil
                }
            case 30: // ]: Next Note (fallback for international layouts)
                if !isCommand && !isControl {
                    self.playerEngine.jumpToNextNote()
                    return nil
                }
            case 33: // [: Previous Note (fallback for international layouts)
                if !isCommand && !isControl {
                    self.playerEngine.jumpToPreviousNote()
                    return nil
                }
            case 48: // Tab key: Rapid Blink / Flicker compare between Slot A and Slot B (Single mode only)
                if self.playerEngine.slotB.url != nil && self.playerEngine.compareMode == .single {
                    self.playerEngine.isBlinkCompareB.toggle()
                    return nil
                }
            case 126: // Up Arrow: Previous file in queue (Slot A, or Option+Up for Slot B)
                if !isCommand && !isControl {
                    if isOption {
                        self.playerSelectPreviousFile(target: .slotB)
                    } else {
                        self.playerSelectPreviousFile(target: .slotA)
                    }
                    return nil
                }
            case 125: // Down Arrow: Next file in queue (Slot A, or Option+Down for Slot B)
                if !isCommand && !isControl {
                    if isOption {
                        self.playerSelectNextFile(target: .slotB)
                    } else {
                        self.playerSelectNextFile(target: .slotA)
                    }
                    return nil
                }
            case 123: // Left Arrow
                if isShift {
                    self.playerEngine.stepFrames(count: 5, forward: false)
                } else {
                    self.playerEngine.stepFrame(forward: false)
                }
                return nil
            case 124: // Right Arrow
                if isShift {
                    self.playerEngine.stepFrames(count: 5, forward: true)
                } else {
                    self.playerEngine.stepFrame(forward: true)
                }
                return nil
            case 115: // Home
                self.playerEngine.jumpToBeginning()
                return nil
            case 119: // End
                self.playerEngine.jumpToEnd()
                return nil
            default:
                break
            }
            
            return event
        }
    }
    
    func playerSelectPreviousFile(target: SlotTarget = .slotA) {
        let files = filteredPlayerFiles
        guard !files.isEmpty else { return }
        let currentURL: URL? = (target == .slotB) ? (playerEngine.slotB.url ?? playerEngine.activeURL) : (playerEngine.activeURL ?? playerEngine.slotA.url)
        if let currentURL = currentURL, let idx = files.firstIndex(where: { isSameURL($0, currentURL) }) {
            let prevIdx = max(0, idx - 1)
            let selectedURL = files[prevIdx]
            revealPlayerFolderContaining(url: selectedURL)
            queueScrollTarget = selectedURL
            playerEngine.loadVideo(url: selectedURL, into: target, autoplay: true)
        } else {
            let selectedURL = files[0]
            revealPlayerFolderContaining(url: selectedURL)
            queueScrollTarget = selectedURL
            playerEngine.loadVideo(url: selectedURL, into: target, autoplay: true)
        }
    }
    
    func playerSelectNextFile(target: SlotTarget = .slotA) {
        let files = filteredPlayerFiles
        guard !files.isEmpty else { return }
        let currentURL: URL? = (target == .slotB) ? (playerEngine.slotB.url ?? playerEngine.activeURL) : (playerEngine.activeURL ?? playerEngine.slotA.url)
        if let currentURL = currentURL, let idx = files.firstIndex(where: { isSameURL($0, currentURL) }) {
            let nextIdx = min(files.count - 1, idx + 1)
            let selectedURL = files[nextIdx]
            revealPlayerFolderContaining(url: selectedURL)
            queueScrollTarget = selectedURL
            playerEngine.loadVideo(url: selectedURL, into: target, autoplay: true)
        } else {
            let selectedURL = files[0]
            revealPlayerFolderContaining(url: selectedURL)
            queueScrollTarget = selectedURL
            playerEngine.loadVideo(url: selectedURL, into: target, autoplay: true)
        }
    }
    
    func jumpToGlitchInPlayer(fileURL: URL, frameIndex: Int) {
        if !videoFiles.contains(fileURL) {
            videoFiles.append(fileURL)
        }
        revealPlayerFolderContaining(url: fileURL)
        queueScrollTarget = fileURL
        playerEngine.loadVideo(url: fileURL, initialSeekFrame: frameIndex)
        playerEngine.pause()
        selectedTab = .player
    }
    
    // MARK: - Next Line Finding Cycler (Tab 3 Findings)
    
    func jumpToNextGlitchFinding() {
        var allGlitches: [(url: URL, frameIndex: Int, timecode: String, label: String)] = []
        for result in scanResults where result.isFlagged {
            for seg in result.glitchSegments {
                allGlitches.append((
                    url: result.fileURL,
                    frameIndex: seg.startFrame,
                    timecode: seg.startTimecode,
                    label: "\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX) @ \(seg.startTimecode)"
                ))
            }
        }
        
        guard !allGlitches.isEmpty else { return }
        
        let currentURL = playerEngine.activeURL
        let currentFrame = playerEngine.currentFrame
        
        var nextTarget: (url: URL, frameIndex: Int, timecode: String, label: String)? = nil
        
        if let currentURL = currentURL {
            let inCurrentFile = allGlitches.filter { $0.url == currentURL }
            if let ahead = inCurrentFile.first(where: { $0.frameIndex > currentFrame + 1 }) {
                nextTarget = ahead
            } else {
                let distinctFlaggedFiles = scanResults.filter { $0.isFlagged && !$0.glitchSegments.isEmpty }.map { $0.fileURL }
                if let currentFileIdx = distinctFlaggedFiles.firstIndex(of: currentURL) {
                    let nextFileIdx = (currentFileIdx + 1) % distinctFlaggedFiles.count
                    let targetURL = distinctFlaggedFiles[nextFileIdx]
                    nextTarget = allGlitches.first(where: { $0.url == targetURL })
                }
            }
        }
        
        let target = nextTarget ?? allGlitches[0]
        jumpToGlitchInPlayer(fileURL: target.url, frameIndex: target.frameIndex)
    }
    
    // MARK: - Previous Line Finding Cycler (Tab 3 Findings)
    
    func jumpToPreviousGlitchFinding() {
        var allGlitches: [(url: URL, frameIndex: Int, timecode: String, label: String)] = []
        for result in scanResults where result.isFlagged {
            for seg in result.glitchSegments {
                allGlitches.append((
                    url: result.fileURL,
                    frameIndex: seg.startFrame,
                    timecode: seg.startTimecode,
                    label: "\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX) @ \(seg.startTimecode)"
                ))
            }
        }
        
        guard !allGlitches.isEmpty else { return }
        
        let currentURL = playerEngine.activeURL
        let currentFrame = playerEngine.currentFrame
        
        var prevTarget: (url: URL, frameIndex: Int, timecode: String, label: String)? = nil
        
        if let currentURL = currentURL {
            let inCurrentFile = allGlitches.filter { $0.url == currentURL }
            // Look for the glitch before the current frame in current file (from closest backwards)
            if let behind = inCurrentFile.last(where: { $0.frameIndex < currentFrame - 1 }) {
                prevTarget = behind
            } else {
                let distinctFlaggedFiles = scanResults.filter { $0.isFlagged && !$0.glitchSegments.isEmpty }.map { $0.fileURL }
                if let currentFileIdx = distinctFlaggedFiles.firstIndex(of: currentURL) {
                    let prevFileIdx = (currentFileIdx - 1 + distinctFlaggedFiles.count) % distinctFlaggedFiles.count
                    let targetURL = distinctFlaggedFiles[prevFileIdx]
                    prevTarget = allGlitches.filter { $0.url == targetURL }.last
                }
            }
        }
        
        let target = prevTarget ?? allGlitches.last ?? allGlitches[0]
        jumpToGlitchInPlayer(fileURL: target.url, frameIndex: target.frameIndex)
    }
    
    // MARK: - Native Finder Tagging
    
    func loadFinderTagsForQueue() {
        let files = videoFiles
        guard !files.isEmpty else {
            fileTagsMap.removeAll()
            return
        }
        Task.detached(priority: .userInitiated) {
            var newMap: [URL: FinderTagColor] = [:]
            for url in files {
                if let tag = FinderTagManager.getTag(for: url) {
                    newMap[url] = tag
                }
            }
            await MainActor.run {
                self.fileTagsMap = newMap
            }
        }
    }
    
    func toggleFinderTag(_ tag: FinderTagColor, for url: URL) {
        if fileTagsMap[url] == tag {
            FinderTagManager.setTag(nil, for: url)
            fileTagsMap.removeValue(forKey: url)
        } else {
            FinderTagManager.setTag(tag, for: url)
            fileTagsMap[url] = tag
        }
    }
    
    func setFinderTag(_ tag: FinderTagColor?, for url: URL) {
        FinderTagManager.setTag(tag, for: url)
        if let tag = tag {
            fileTagsMap[url] = tag
        } else {
            fileTagsMap.removeValue(forKey: url)
        }
    }
    
    // MARK: - File Properties Modal (Premiere Pro Style)
    
    func openProperties(for url: URL) {
        propertiesURL = url
        if let existing = deliverableAssets.first(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
            propertiesAsset = existing
            isInspectingProperties = false
            withAnimation(.easeInOut(duration: 0.15)) {
                showPropertiesModal = true
            }
        } else {
            propertiesAsset = nil
            isInspectingProperties = true
            withAnimation(.easeInOut(duration: 0.15)) {
                showPropertiesModal = true
            }
            
            Task { @MainActor in
                if let asset = await DeliverablesInspector.inspectFile(url: url) {
                    self.propertiesAsset = asset
                    if !self.deliverableAssets.contains(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
                        self.deliverableAssets.append(asset)
                    }
                }
                self.isInspectingProperties = false
            }
        }
    }
    
    func togglePropertiesModalForActiveOrSelected() {
        if showPropertiesModal {
            withAnimation(.easeInOut(duration: 0.15)) {
                showPropertiesModal = false
            }
            return
        }
        
        if selectedTab == .specs {
            let targetURL = selectedDeliverableURL ?? deliverableAssets.first?.fileURL
            if let url = targetURL {
                openProperties(for: url)
            }
            return
        }
        
        let targetURL = (playerEngine.activeTarget == .slotB && playerEngine.slotB.url != nil) ? playerEngine.slotB.url : (playerEngine.activeURL ?? playerEngine.slotA.url ?? filteredPlayerFiles.first)
        if let url = targetURL {
            openProperties(for: url)
        }
    }
    
    // MARK: - Timecoded Notes Management (Frame.io Style)
    
    func syncScanResultsToNotes(results: [VideoQCResult]) {
        Task {
            for result in results {
                var notes = await QCNotesManager.shared.loadNotes(for: result.fileURL)
                notes.removeAll { $0.author == "Line QC" }
                
                if result.isFlagged && !result.glitchSegments.isEmpty {
                    for seg in result.glitchSegments {
                        let edgePos = seg.edge.rawValue.contains("Screen") ? seg.edge.rawValue : "\(seg.edge.rawValue) Edge"
                        let durationInfo = seg.frameCount > 1 ? " (\(seg.frameCount) frames, \(String(format: "%.2fs", seg.durationSeconds)))" : ""
                        let noteText = "\(edgePos) (\(seg.avgThickness)px) — Line glitch detected [\(seg.detectedColor.hexString.uppercased())]\(durationInfo)"
                        
                        let note = QCFileNote(
                            frameIndex: seg.startFrame,
                            timecode: seg.startTimecode,
                            author: "Line QC",
                            text: noteText,
                            colorTag: "red",
                            createdAt: Date(),
                            isResolved: false
                        )
                        notes.append(note)
                    }
                    notes.sort { $0.frameIndex < $1.frameIndex }
                }
                
                await QCNotesManager.shared.saveNotes(notes, for: result.fileURL, fps: result.fps)
                
                if let activeURL = self.playerEngine.activeURL, activeURL == result.fileURL {
                    let updatedNotes = notes
                    await MainActor.run {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            self.playerEngine.activeNotes = updatedNotes
                        }
                    }
                }
            }
        }
    }
    
    func loadNotesForActiveURL(_ url: URL?) {
        guard let url = url else {
            playerEngine.activeNotes = []
            return
        }
        Task { @MainActor in
            var notes = await QCNotesManager.shared.loadNotes(for: url)
            if let result = self.scanResults.first(where: { $0.fileURL == url && $0.isFlagged && !$0.glitchSegments.isEmpty }) {
                let hasQCNotes = notes.contains { $0.author == "Line QC" }
                if !hasQCNotes {
                    for seg in result.glitchSegments {
                        let edgePos = seg.edge.rawValue.contains("Screen") ? seg.edge.rawValue : "\(seg.edge.rawValue) Edge"
                        let durationInfo = seg.frameCount > 1 ? " (\(seg.frameCount) frames, \(String(format: "%.2fs", seg.durationSeconds)))" : ""
                        let noteText = "\(edgePos) (\(seg.avgThickness)px) — Line glitch detected [\(seg.detectedColor.hexString.uppercased())]\(durationInfo)"
                        notes.append(QCFileNote(
                            frameIndex: seg.startFrame,
                            timecode: seg.startTimecode,
                            author: "Line QC",
                            text: noteText,
                            colorTag: "red",
                            createdAt: Date(),
                            isResolved: false
                        ))
                    }
                    notes.sort { $0.frameIndex < $1.frameIndex }
                }
            }
            if self.playerEngine.activeURL == url {
                self.playerEngine.activeNotes = notes
            }
        }
    }
    
    func openAddNoteModal() {
        guard playerEngine.activeURL != nil else { return }
        playerEngine.pause()
        withAnimation(.easeInOut(duration: 0.15)) {
            showAddNoteModal = true
        }
    }
    
    func addNote(_ note: QCFileNote) {
        guard let url = playerEngine.activeURL else { return }
        var currentNotes = playerEngine.activeNotes
        currentNotes.append(note)
        currentNotes.sort { $0.frameIndex < $1.frameIndex }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            playerEngine.activeNotes = currentNotes
        }
        saveNotes(currentNotes, for: url)
        showToast("Note logged at \(note.timecode)")
    }
    
    func toggleNoteResolved(id: UUID) {
        guard let url = playerEngine.activeURL else { return }
        guard let index = playerEngine.activeNotes.firstIndex(where: { $0.id == id }) else { return }
        playerEngine.activeNotes[index].isResolved.toggle()
        saveNotes(playerEngine.activeNotes, for: url)
    }
    
    func deleteNote(id: UUID) {
        guard let url = playerEngine.activeURL else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            playerEngine.activeNotes.removeAll(where: { $0.id == id })
        }
        saveNotes(playerEngine.activeNotes, for: url)
        showToast("Note deleted")
    }
    
    func saveNotes(_ notes: [QCFileNote], for url: URL) {
        let fps = playerEngine.activeFps
        Task {
            await QCNotesManager.shared.saveNotes(notes, for: url, fps: fps)
        }
    }
}

// MARK: - Isolated Studio Status Bar View
struct StudioStatusBarView: View {
    @ObservedObject private var hoverCoordinator = HoverExplanationCoordinator.shared
    let textMuted: Color
    let textMain: Color
    
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 9))
                    .foregroundColor(hoverCoordinator.text.isEmpty ? textMuted : textMain)
                Text("INFO //")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(hoverCoordinator.text.isEmpty ? textMuted : textMain)
            }
            
            Text(hoverCoordinator.text.isEmpty ? "Hover over any button, field, or control for function details." : hoverCoordinator.text)
                .font(.system(size: 10, weight: hoverCoordinator.text.isEmpty ? .regular : .semibold, design: .monospaced))
                .foregroundColor(hoverCoordinator.text.isEmpty ? textMuted : textMain)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            Text("v\(AppVersionInfo.version)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
        }
    }
}

