import SwiftUI
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import VideoQCLib

struct ContentView: View {
    @AppStorage("isLightMode") var isLightMode: Bool = false
    @State var selectedTab: AppTab = .lineScanner
    @State var showUserGuide: Bool = false
    @State var showFeedbackModal: Bool = false
    @State var showShortcutsModal: Bool = false
    @State var showSettingsPopover: Bool = false
    @State var showThemeModal: Bool = false
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State var hoverExplanation: String = ""
    
    // Shared Folder & Video Files
    @State var folderURL: URL? = nil
    @State var videoFiles: [URL] = []
    
    // MARK: - Tab 1: Line Scanner State
    @State var hexCode: String = "#00FF00"
    @State var tolerancePercentage: Double = 25.0
    @State var edgeDepth: Int = 12
    @State var minSpanPercentage: Double = 70.0
    @State var scanFullScreen: Bool = false
    @State var enableExposureBoost: Bool = true
    @State var exposureMultiplier: Double = 10.0
    @State var ignoreFullBlackFrames: Bool = true
    
    @State var isScanning: Bool = false
    @State var isAuditBtnHovered: Bool = false
    @State var progressInfo: VideoScanner.ScanProgress? = nil
    @State var scanResults: [VideoQCResult] = []
    @State var lastScanConfig: QCConfig? = nil
    @State var generatedReportURL: URL? = nil
    @State var generatedCSVURL: URL? = nil
    @State var scannerActor: VideoScanner? = nil
    
    // MARK: - Tab 3: Deliverables Specs State
    @State var deliverableAssets: [DeliverableAsset] = []
    @State var isInspectingDeliverables: Bool = false
    @State var manifestCSVURL: URL? = nil
    @State var manifestHTMLURL: URL? = nil
    @State var deliverablesCollapsedFolderIDs: Set<String> = []
    
    // MARK: - Tab 4: Batch Renamer State
    @State var renamerCollapsedFolderIDs: Set<String> = []
    @State var renameMode: RenameMode = .template
    @State var customNameText: String = ""
    @State var templateText: String = "{NAME}_{DUR}sec_{RATIO}"
    @State var findText: String = ""
    @State var replaceText: String = ""
    @State var prefixText: String = ""
    @State var suffixText: String = ""
    @State var customTag1: String = ""
    @State var customTag2: String = ""
    @State var customTag3: String = ""
    @State var textCase: TextCaseOption = .uppercase
    @State var indexStart: Int = 1
    @State var indexPadding: Int = 2
    @State var lastTransaction: RenameTransaction? = nil
    @State var selectedAssetIDs: Set<UUID> = []
    @State var directoryFilesCache: [URL: Set<String>] = [:]
    
    // MARK: - Folder Grouping State
    @State var hideAllFolders: Bool = false
    @State var hiddenFolderIDs: Set<String> = []
    
    // MARK: - Tab 2: Player State
    @StateObject var playerEngine = PlayerEngine()
    @State var playerFilterText: String = ""
    @State var playerCollapsedFolderIDs: Set<String> = []
    @State var fileTagsMap: [URL: FinderTagColor] = [:]
    @State var showTagPickerPopover: Bool = false
    @State private var hasSetupKeyboardMonitor: Bool = false
    @State private var eventMonitors = EventMonitorCoordinator()
    
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
    
    var renameItems: [RenameItem] {
        RenamerEngine.generateProposedItems(
            assets: deliverableAssets,
            mode: renameMode,
            customName: customNameText,
            templateString: templateText,
            findString: findText,
            replaceString: replaceText,
            prefixString: prefixText,
            suffixString: suffixText,
            customTag: customTag1,
            customTag2: customTag2,
            customTag3: customTag3,
            caseOption: textCase,
            indexStart: indexStart,
            indexPadding: indexPadding,
            selectedAssetIDs: selectedAssetIDs,
            existingFilesByDir: directoryFilesCache
        )
    }
    
    var isTargetBlack: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    let colorPresets = [
        ("GREEN", "#00FF00", 25.0),
        ("MAGENTA", "#FF00B4", 25.0),
        ("BLACK", "#000000", 3.0)
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
            VStack(spacing: 0) {
                // 1. Top Masthead
                headerView
                
                Rectangle()
                    .fill(borderLine)
                    .frame(height: 1)
                
                // 2. Dedicated Prominent Tab Navigation Bar
                tabBarStrip
                
                Rectangle()
                    .fill(borderLine)
                    .frame(height: 1)
                
                // 3. Main Tab Content
                switch selectedTab {
                case .lineScanner:
                    lineScannerTabView
                case .player:
                    playerTabView
                case .deliverables:
                    deliverablesTabView
                case .batchRenamer:
                    batchRenamerTabView
                }
                
                // 4. Bottom Contextual Explanation Bar
                Rectangle()
                    .fill(borderLine)
                    .frame(height: 1)
                
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 9))
                            .foregroundColor(hoverExplanation.isEmpty ? textMuted : textMain)
                        Text("INFO //")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(hoverExplanation.isEmpty ? textMuted : textMain)
                    }
                    
                    Text(hoverExplanation.isEmpty ? "Hover over any button, field, or control for function details." : hoverExplanation)
                        .font(.system(size: 10, weight: hoverExplanation.isEmpty ? .regular : .semibold, design: .monospaced))
                        .foregroundColor(hoverExplanation.isEmpty ? textMuted : textMain)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Text("v\(AppVersionInfo.version)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(bgPanel)
            }
            .frame(minWidth: 1000, minHeight: 720)
            .background(bgMain)
            .foregroundColor(textMain)
            
            // In-App Operation Guide Overlay Modal
            if showUserGuide {
                UserGuideView(isPresented: $showUserGuide)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(100)
            }
            
            // Feedback Form Overlay Modal
            if showFeedbackModal {
                FeedbackModalView(isPresented: $showFeedbackModal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(150)
            }
            
            // Keyboard Shortcuts Overlay Modal
            if showShortcutsModal {
                ShortcutsModalView(isPresented: $showShortcutsModal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(155)
            }
            
            // Theme & Accent Colors Overlay Modal
            if showThemeModal {
                ThemeSettingsModalView(isPresented: $showThemeModal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(158)
            }
            
            // Software Update Overlay Modal
            if updateManager.showModal {
                UpdateModalView(updateManager: updateManager, isPresented: $updateManager.showModal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(160)
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
        }
        .animation(.easeInOut(duration: 0.15), value: showUserGuide)
        .animation(.easeInOut(duration: 0.15), value: showFeedbackModal)
        .animation(.easeInOut(duration: 0.15), value: showShortcutsModal)
        .animation(.easeInOut(duration: 0.15), value: showThemeModal)
        .animation(.easeInOut(duration: 0.15), value: fullscreenMode)
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
        .onAppear {
            setupKeyboardMonitor()
            loadFinderTagsForQueue()
            updateManager.checkForUpdates(userInitiated: false)
        }
        .onDisappear {
            eventMonitors.cleanup()
            hasSetupKeyboardMonitor = false
        }
    }
    
    // MARK: - Header & Navigation
    
    private var headerView: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(textMain)
                    .frame(width: 4, height: 26)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("QCpie")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .tracking(1.5)
                        .foregroundColor(textMain)
                    
                    Text("STUDIO QC • FRAME AUDIT • ASSET SPECS • BATCH RENAMER")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                        .tracking(0.5)
                }
            }
            
            Spacer()
            
            HStack(spacing: 10) {
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
                
                // Theme Toggle (Square 26x26 with Sun / Moon icon)
                Button(action: { isLightMode.toggle() }) {
                    Image(systemName: isLightMode ? "sun.max.fill" : "moon.stars.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .explain("Switch to \(isLightMode ? "Dark" : "Light") mode theme.", binding: $hoverExplanation)
                
                // Settings Menu Button (Clean square gear button with zero chevron)
                Button(action: { showSettingsPopover.toggle() }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 26, height: 26)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                        
                        if updateManager.hasUpdate {
                            Circle()
                                .fill(accentPositive)
                                .frame(width: 6, height: 6)
                                .offset(x: -2, y: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .explain("Settings: Software Update, Info & Guide, and Feedback.", binding: $hoverExplanation)
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: {
                            showSettingsPopover = false
                            updateManager.checkForUpdates(userInitiated: true)
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
                            showThemeModal = true
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
                            showUserGuide.toggle()
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
                            showFeedbackModal = true
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
                
                // Engine Status Indicator (Fixed 76px width)
                HStack(spacing: 6) {
                    Circle()
                        .fill(isScanning || isInspectingDeliverables ? textMain : accentPositive)
                        .frame(width: 7, height: 7)
                    Text(isScanning || isInspectingDeliverables ? "BUSY" : "READY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(isScanning || isInspectingDeliverables ? textSubtle : accentPositive)
                        .tracking(1.0)
                }
                .frame(width: 76, height: 26)
                .studioBox(background: bgSubtle, border: borderLine)
                .explain(isScanning || isInspectingDeliverables ? "Engine is currently processing video files." : "Engine is idle and ready for new jobs.", binding: $hoverExplanation)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(bgPanel)
    }
    
    private func tabWidth(for tab: AppTab) -> CGFloat {
        switch tab {
        case .lineScanner: return 260
        case .deliverables: return 165
        case .batchRenamer: return 220
        case .player: return 165
        }
    }
    
    private var tabBarStrip: some View {
        HStack(spacing: 10) {
            ForEach(AppTab.allCases) { tab in
                Button(action: {
                    selectedTab = tab
                    if (tab == .deliverables || tab == .batchRenamer) && deliverableAssets.isEmpty && !videoFiles.isEmpty {
                        inspectDeliverablesBatch(urls: videoFiles)
                    } else if tab == .player && playerEngine.activeURL == nil, let first = videoFiles.first {
                        playerEngine.loadVideo(url: first)
                    }
                }) {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(selectedTab == tab ? accentBlue : Color.clear)
                            .frame(width: 4, height: 16)
                        
                        Text(tab.title)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(0.5)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        
                        Spacer(minLength: 6)
                        
                        if (tab == .deliverables || tab == .batchRenamer) && !deliverableAssets.isEmpty {
                            Text("[\(deliverableAssets.count)]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(selectedTab == tab ? primaryBtnFg : textSubtle)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        } else if tab == .player && !videoFiles.isEmpty {
                            Text("[\(videoFiles.count)]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(selectedTab == tab ? primaryBtnFg : textSubtle)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        } else if tab == .lineScanner && !scanResults.isEmpty {
                            let flaggedCount = scanResults.filter { $0.isFlagged }.count
                            Text(flaggedCount > 0 ? "[\(flaggedCount) FLAGGED]" : "[PASSED]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(flaggedCount > 0 ? alertRed : accentPositive)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .frame(width: tabWidth(for: tab))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .foregroundColor(selectedTab == tab ? primaryBtnFg : textSubtle)
                    .studioBox(background: selectedTab == tab ? primaryBtnBg : bgSubtle, border: selectedTab == tab ? primaryBtnBg : borderLine)
                }
                .buttonStyle(.plain)
                .explain(
                    tab == .lineScanner ? "01 // LINE SCANNER: Scans video frames for edge line glitches and blanking errors." :
                    (tab == .player ? "02 // PLAYER: High-performance delivery playback with J-K-L shuttle, timeline scrubbing, and zoom." :
                     (tab == .deliverables ? "03 // DELIVERABLES SPECS: Reads container resolution, timecode, audio, and codecs." :
                      "04 // BATCH RENAMER: Renames files using inspected video metadata and custom templates.")),
                    binding: $hoverExplanation
                )
            }
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(bgCardHeader)
    }
    
    // MARK: - Reusable Unified Asset Selection Section
    
    func deliveryAssetsSection(forTab: AppTab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "01", title: "LOAD ASSETS")
            
            VStack(alignment: .leading, spacing: 8) {
                // 3 Action Buttons on the same line: CHANGE, ADD, HIDE
                HStack(spacing: 4) {
                    // CHANGE / SELECT Button
                    Button(action: { selectAssets(forTab: forTab, append: false) }) {
                        HStack(spacing: 3) {
                            Image(systemName: folderURL == nil && videoFiles.isEmpty ? "folder.badge.plus" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 8, weight: .bold))
                            Text(folderURL == nil && videoFiles.isEmpty ? "SELECT" : "CHANGE")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .explain(folderURL == nil && videoFiles.isEmpty ? "Opens file picker to select video files or a folder to inspect." : "Replaces currently loaded assets with a new folder or file selection.", binding: $hoverExplanation)
                    
                    // ADD Button
                    Button(action: { selectAssets(forTab: forTab, append: true) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                            Text("ADD")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .explain("Opens file picker to add more video files or folders to current list without losing existing assets.", binding: $hoverExplanation)
                    
                    // HIDE / SHOW Folders Button
                    let isHidden = hideAllFolders || !hiddenFolderIDs.isEmpty
                    let canToggle = hasPlayerSubfolders || !videoFiles.isEmpty
                    Button(action: toggleHideFolders) {
                        HStack(spacing: 3) {
                            Image(systemName: isHidden ? "folder" : "folder.badge.minus")
                                .font(.system(size: 8, weight: .bold))
                            Text(isHidden ? "SHOW" : "HIDE")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundColor(canToggle ? textMain : textSubtle)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning || !canToggle)
                    .explain(isHidden ? "Show all folder headers in asset lists." : "Hide folder headers and display assets in a flat list.", binding: $hoverExplanation)
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
            renamerCollapsedFolderIDs.subtract(allFolderIDs)
            hiddenFolderIDs.subtract(allFolderIDs)
            
            if videoFiles.isEmpty {
                folderURL = nil
            } else {
                folderURL = determineFolderURL(for: videoFiles, detectedFolder: folderURL)
            }
            
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
                        let ext = url.pathExtension.lowercased()
                        if ["mp4", "mov", "m4v", "mkv", "avi", "prores"].contains(ext) {
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
                self.renamerCollapsedFolderIDs = []
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
            let loadedURLs = collector.urls
            var collectedVideos: [URL] = []
            var detectedFolder: URL? = nil
            
            for url in loadedURLs {
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
                        let ext = url.pathExtension.lowercased()
                        if ["mp4", "mov", "m4v", "mkv", "avi", "prores"].contains(ext) {
                            collectedVideos.append(url)
                        }
                    }
                }
            }
            
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
            
            if newlyAdded.isEmpty {
                // If dropping into a specific slot and the file was already in queue, still load it into target slot
                if let targetSlot = targetSlot, let existing = collectedVideos.first {
                    self.playerEngine.loadVideo(url: existing, into: targetSlot)
                }
                return
            }
            
            self.videoFiles = mergedVideos
            self.folderURL = self.determineFolderURL(for: mergedVideos, detectedFolder: self.folderURL ?? detectedFolder)
            
            // Inspect only newly added deliverables and append to existing deliverables
            self.inspectDeliverablesBatch(urls: newlyAdded, append: true)
            self.loadFinderTagsForQueue()
            
            if let targetSlot = targetSlot {
                if let first = newlyAdded.first {
                    self.playerEngine.loadVideo(url: first, into: targetSlot)
                }
            } else if self.playerEngine.activeURL == nil, let first = newlyAdded.first {
                self.playerEngine.loadVideo(url: first)
            }
        }
        return true
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
            ignoreFullBlackFrames: ignoreFullBlackFrames
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
            
            // Build directory files cache off the main thread
            var cache: [URL: Set<String>] = [:]
            let dirs = Set(urls.map { $0.deletingLastPathComponent() })
            for dir in dirs {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                cache[dir] = Set(files.map { $0.lowercased() })
            }
            
            DispatchQueue.main.async {
                if append {
                    var existingMap = Dictionary(uniqueKeysWithValues: self.deliverableAssets.map { ($0.fileURL.standardizedFileURL, $0) })
                    for asset in assets {
                        let key = asset.fileURL.standardizedFileURL
                        if existingMap[key] == nil {
                            existingMap[key] = asset
                            self.deliverableAssets.append(asset)
                            self.selectedAssetIDs.insert(asset.id)
                        }
                    }
                    self.directoryFilesCache.merge(cache) { _, new in new }
                } else {
                    self.deliverableAssets = assets
                    self.directoryFilesCache = cache
                    self.selectedAssetIDs = Set(assets.map { $0.id })
                }
                self.isInspectingDeliverables = false
            }
        }
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
    
    // MARK: - Reusable UI Subviews & Helpers
    
    func sectionHeader(num: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(num)
                .font(.system(size: 9, weight: .black, design: .monospaced))
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
            // Only capture if on the player tab
            guard self.selectedTab == .player else { return event }
            
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
            
            // ESC key: Dismiss shortcuts modal or exit fullscreen
            if event.keyCode == 53 {
                if self.showShortcutsModal {
                    self.showShortcutsModal = false
                    return nil
                }
                if self.fullscreenMode != .none {
                    self.exitFullscreen()
                    return nil
                }
            }
            
            // If shortcuts modal is active, block background player controls
            if self.showShortcutsModal {
                return event
            }
            
            let isShift = event.modifierFlags.contains(.shift)
            let isCommand = event.modifierFlags.contains(.command)
            
            // J K L Shuttle
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if chars == "j" {
                    if isShift {
                        self.playerEngine.pressSlowJ()
                    } else {
                        self.playerEngine.pressJ()
                    }
                    return nil
                } else if chars == "k" {
                    self.playerEngine.pressK()
                    return nil
                } else if chars == "l" && !isCommand {
                    if isShift {
                        self.playerEngine.pressSlowL()
                    } else {
                        self.playerEngine.pressL()
                    }
                    return nil
                } else if chars == "l" && isCommand {
                    self.playerEngine.isLooping.toggle()
                    return nil
                } else if chars == " " { // Spacebar
                    self.playerEngine.togglePlayPause()
                    return nil
                } else if chars == "f" && !isCommand { // F: Toggle Video Fullscreen (Clean) / Shift+F: Review Fullscreen
                    if self.fullscreenMode != .none {
                        self.exitFullscreen()
                    } else if self.playerEngine.activeURL != nil {
                        self.enterFullscreen(mode: isShift ? .review : .videoOnly)
                    }
                    return nil
                } else if chars == "n" { // N: Jump to Next Line Finding / Shift+N: Previous Line Finding
                    if isShift {
                        self.jumpToPreviousGlitchFinding()
                    } else {
                        self.jumpToNextGlitchFinding()
                    }
                    return nil
                } else if chars == "x" && !isCommand { // X: Swap Slot A and Slot B
                    if self.selectedTab == .player && self.playerEngine.slotB.url != nil {
                        self.playerEngine.swapSlots()
                        return nil
                    }
                } else if chars == "c" && !isCommand { // C: Cycle compare modes
                    if self.selectedTab == .player && self.playerEngine.slotB.url != nil {
                        self.playerEngine.cycleCompareMode()
                        return nil
                    }
                } else if chars == "?" || (isCommand && chars == "/") {
                    self.showShortcutsModal.toggle()
                    return nil
                }
            }
            
            switch event.keyCode {
            case 48: // Tab key: Rapid Blink / Flicker compare between Slot A and Slot B
                if self.selectedTab == .player && self.playerEngine.slotB.url != nil {
                    self.playerEngine.isBlinkCompareB.toggle()
                    return nil
                }
            case 126: // Up Arrow: Previous file in queue
                self.playerSelectPreviousFile()
                return nil
            case 125: // Down Arrow: Next file in queue
                self.playerSelectNextFile()
                return nil
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
    
    func playerSelectPreviousFile() {
        let files = filteredPlayerFiles
        guard !files.isEmpty else { return }
        let target = playerEngine.activeTarget
        let currentURL = (target == .slotB && playerEngine.slotB.url != nil) ? playerEngine.slotB.url : playerEngine.activeURL
        if let currentURL = currentURL, let idx = files.firstIndex(of: currentURL) {
            let prevIdx = max(0, idx - 1)
            let selectedURL = files[prevIdx]
            revealPlayerFolderContaining(url: selectedURL)
            playerEngine.loadVideo(url: selectedURL, into: target)
        } else {
            let selectedURL = files[0]
            revealPlayerFolderContaining(url: selectedURL)
            playerEngine.loadVideo(url: selectedURL, into: target)
        }
    }
    
    func playerSelectNextFile() {
        let files = filteredPlayerFiles
        guard !files.isEmpty else { return }
        let target = playerEngine.activeTarget
        let currentURL = (target == .slotB && playerEngine.slotB.url != nil) ? playerEngine.slotB.url : playerEngine.activeURL
        if let currentURL = currentURL, let idx = files.firstIndex(of: currentURL) {
            let nextIdx = min(files.count - 1, idx + 1)
            let selectedURL = files[nextIdx]
            revealPlayerFolderContaining(url: selectedURL)
            playerEngine.loadVideo(url: selectedURL, into: target)
        } else {
            let selectedURL = files[0]
            revealPlayerFolderContaining(url: selectedURL)
            playerEngine.loadVideo(url: selectedURL, into: target)
        }
    }
    
    func jumpToGlitchInPlayer(fileURL: URL, frameIndex: Int) {
        if !videoFiles.contains(fileURL) {
            videoFiles.append(fileURL)
        }
        revealPlayerFolderContaining(url: fileURL)
        playerEngine.loadVideo(url: fileURL, initialSeekFrame: frameIndex)
        playerEngine.pause()
        selectedTab = .player
    }
    
    // MARK: - Next Line Finding Cycler (Tab 1 Findings)
    
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
    
    // MARK: - Previous Line Finding Cycler (Tab 1 Findings)
    
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
}
