import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib

// MARK: - Minimal Borderless Transport Button Style

struct TransportIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ContentView {
    
    // MARK: ==================== TAB 2: PREMIERE-STYLE PLAYER ====================
    
    var playerTabView: some View {
        HSplitView {
            // MARK: - Left Panel: Video Queue & Explorer
            VStack(alignment: .leading, spacing: 18) {
                // Asset Picker Section
                deliveryAssetsSection(forTab: .player)
                
                // Search Filter
                if !videoFiles.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        
                        ZStack(alignment: .leading) {
                            if playerFilterText.isEmpty {
                                Text("FILTER ASSETS...")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMuted)
                                    .allowsHitTesting(false)
                            }
                            TextField("", text: $playerFilterText)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .textFieldStyle(.plain)
                                .foregroundColor(textMain)
                                .onSubmit {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                }
                        }
                        
                        if !playerFilterText.isEmpty {
                            Button(action: { playerFilterText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .studioBox(background: bgSubtle, border: borderLine)
                }
                
                // Asset List
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("QUEUE (\(filteredPlayerFiles.count))")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(textMuted)
                        
                        if hasPlayerSubfolders && !hideAllFolders {
                            Button(action: toggleAllPlayerFolders) {
                                Image(systemName: playerCollapsedFolderIDs.isEmpty ? "chevron.down.circle" : "chevron.right.circle")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(textMuted)
                            }
                            .buttonStyle(.plain)
                            .explain(playerCollapsedFolderIDs.isEmpty ? "Collapse all folders in playback queue." : "Expand all folders in playback queue.", binding: $hoverExplanation)
                        }
                        
                        Spacer()
                        
                        // Slot Target Selector
                        HStack(spacing: 3) {
                            Text("TARGET:")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            
                            Button(action: { playerEngine.activeTarget = .slotA }) {
                                Text("A")
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .frame(width: 18, height: 18)
                                    .foregroundColor(playerEngine.activeTarget == .slotA ? accentPositive : textMuted)
                                    .studioBox(background: playerEngine.activeTarget == .slotA ? accentPositive.opacity(0.18) : bgSubtle,
                                               border: playerEngine.activeTarget == .slotA ? accentPositive : borderLine)
                            }
                            .buttonStyle(.plain)
                            .explain("Target Slot A (Master) for queue clicks", binding: $hoverExplanation)
                            
                            Button(action: { playerEngine.activeTarget = .slotB }) {
                                Text("B")
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .frame(width: 18, height: 18)
                                    .foregroundColor(playerEngine.activeTarget == .slotB ? accentSlotB : textMuted)
                                    .studioBox(background: playerEngine.activeTarget == .slotB ? accentSlotB.opacity(0.18) : bgSubtle,
                                               border: playerEngine.activeTarget == .slotB ? accentSlotB : borderLine)
                            }
                            .buttonStyle(.plain)
                            .explain("Target Slot B (Compare) for queue clicks (or ⌥+Click)", binding: $hoverExplanation)
                            
                            if playerEngine.slotB.url != nil {
                                Button(action: { playerEngine.swapSlots() }) {
                                    Image(systemName: "arrow.left.arrow.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .frame(width: 18, height: 18)
                                        .foregroundColor(textMain)
                                        .studioBox(background: bgSubtle, border: borderLine)
                                }
                                .buttonStyle(.plain)
                                .explain("Swap Slot A and Slot B (X)", binding: $hoverExplanation)
                            }
                        }
                    }
                    
                    if videoFiles.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "film")
                                .font(.system(size: 24))
                                .foregroundColor(textMuted)
                            Text("NO VIDEO FILES LOADED")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            Text("Select or drop a folder to populate playback queue.")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(textSubtle)
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                        .studioBox(background: bgCardSubtle, border: borderLine)
                    } else {
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    if hasPlayerSubfolders {
                                        ForEach(flattenedPlayerNodes) { node in
                                            if node.isDirectory {
                                                playerFolderRow(node: node)
                                                    .id(node.id)
                                            } else {
                                                playerFileRow(url: node.url, depth: node.depth)
                                                    .id(node.url)
                                            }
                                        }
                                    } else {
                                        ForEach(filteredPlayerFiles, id: \.self) { url in
                                            playerFileRow(url: url, depth: 0)
                                                .id(url)
                                        }
                                    }
                                }
                            }
                            .onChange(of: playerEngine.activeURL) { _, newURL in
                                if let newURL = newURL {
                                    revealPlayerFolderContaining(url: newURL)
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        scrollProxy.scrollTo(newURL, anchor: .center)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            scrollProxy.scrollTo(newURL, anchor: .center)
                                        }
                                    }
                                }
                            }
                            .onChange(of: playerEngine.slotB.url) { _, newURL in
                                if let newURL = newURL, playerEngine.activeTarget == .slotB {
                                    revealPlayerFolderContaining(url: newURL)
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        scrollProxy.scrollTo(newURL, anchor: .center)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            scrollProxy.scrollTo(newURL, anchor: .center)
                                        }
                                    }
                                }
                            }
                        }
                        .studioBox(background: bgCardSubtle, border: borderLine)
                        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                            handleDrop(providers: providers, forTab: .player)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(22)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDrop(providers: providers, forTab: .player)
            }
            
            // MARK: - Right Panel: Program Monitor & Timeline
            VStack(spacing: 0) {
                // Monitor Header Bar
                playerMonitorHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .studioBox(background: bgCardHeader, border: borderLine)
                
                // Program Monitor Viewport Canvas
                GeometryReader { vpGeo in
                    ZStack(alignment: .topLeading) {
                        if playerEngine.slotA.url != nil || playerEngine.slotB.url != nil {
                            VideoViewportView(engine: playerEngine, isLightMode: isLightMode)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(textMuted)
                                Text("NO VIDEO SELECTED")
                                    .font(.system(size: 13, weight: .black, design: .monospaced))
                                    .foregroundColor(textMain)
                                Text("Click a file from the queue on the left to begin inspecting.")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(textSubtle)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(bgMain)
                        }
                        
                        // Dual A/B Mode: Clip Names at top-left of canvas (Togglable)
                        if playerEngine.slotB.url != nil && playerEngine.showClipNamesOverlay {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text("A:")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundColor(accentPositive)
                                    Text(playerEngine.slotA.fileName.isEmpty ? "--" : playerEngine.slotA.fileName.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                HStack(spacing: 5) {
                                    Text("B:")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundColor(accentSlotB)
                                    Text(playerEngine.slotB.fileName.isEmpty ? "--" : playerEngine.slotB.fileName.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.70))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .padding(10)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers, location in
                        handleViewportDrop(providers: providers, location: location, viewportWidth: vpGeo.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioBox(background: Color(white: 0.08), border: borderLine)
                
                // Timeline Scrubber & Transport Controls (Rigidly locked height to prevent any layout jitter)
                VStack(spacing: 8) {
                    // Timecode, Play Info & Zoom (centered above timeline)
                    playerTimecodeBar
                        .frame(height: 24)
                    
                    // Timeline Scrubber
                    TimelineScrubberView(engine: playerEngine, isLightMode: isLightMode)
                        .frame(height: 46)
                        .disabled(playerEngine.activeURL == nil)
                    
                    // Transport Strip
                    playerTransportBar
                        .frame(height: 28)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .studioBox(background: bgCardHeader, border: borderLine)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDrop(providers: providers, forTab: .player)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers, forTab: .player)
        }
        .onAppear {
            // Automatically select first file if none loaded
            if playerEngine.activeURL == nil, let first = videoFiles.first {
                playerEngine.loadVideo(url: first)
            }
        }
    }
    
    // MARK: - Folder & File Rows
    
    private func playerFolderRow(node: FileSystemTreeNode) -> some View {
        let isCollapsed = playerCollapsedFolderIDs.contains(node.id)
        
        return HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(textMuted)
                .frame(width: 12)
            
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(textSubtle)
            
            Text(node.name.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(textMain)
                .lineLimit(1)
            
            Spacer()
            
            Text("\(node.videoCount)")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(textSubtle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(bgSubtle))
        }
        .padding(.leading, CGFloat(node.depth * 14) + 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed {
                playerCollapsedFolderIDs.remove(node.id)
            } else {
                playerCollapsedFolderIDs.insert(node.id)
            }
        }
        .explain(node.url.path, binding: $hoverExplanation)
        .contextMenu {
            Button("Hide Folder") {
                hideSpecificFolder(id: node.id)
            }
            Button("Clear Folder") {
                clearFolder(node: node)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }
    
    private func playerFileRow(url: URL, depth: Int = 0) -> some View {
        let isSlotA = playerEngine.slotA.url == url
        let isSlotB = playerEngine.slotB.url == url
        let isSelected = isSlotA || isSlotB
        let currentTag = fileTagsMap[url]
        
        return HStack(spacing: 6) {
            // Row Click to Load
            Button(action: {
                if NSEvent.modifierFlags.contains(.option) {
                    playerEngine.loadVideo(url: url, into: .slotB)
                } else {
                    playerEngine.loadVideo(url: url, into: playerEngine.activeTarget)
                }
            }) {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(isSlotA ? accentPositive : (isSlotB ? accentSlotB : Color.clear))
                        .frame(width: 3)
                    
                    if depth > 0 {
                        Spacer().frame(width: CGFloat(depth * 14))
                    }
                    
                    Image(systemName: isSlotA ? "a.circle.fill" : (isSlotB ? "b.circle.fill" : "play.circle.fill"))
                        .font(.system(size: 13))
                        .foregroundColor(isSlotA ? accentPositive : (isSlotB ? accentSlotB : textMuted))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let tag = currentTag {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 7, height: 7)
                            }
                            Text(url.lastPathComponent)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected ? textMain : textSubtle)
                                .lineLimit(1)
                        }
                        
                        // Metadata line
                        if isSlotA && !playerEngine.slotA.resolution.isEmpty {
                            Text("\(playerEngine.slotA.resolution) • \(String(format: "%.1f", playerEngine.slotA.fps))fps • \(playerEngine.slotA.codec)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(accentPositive)
                                .lineLimit(1)
                        } else if isSlotB && !playerEngine.slotB.resolution.isEmpty {
                            Text("\(playerEngine.slotB.resolution) • \(String(format: "%.1f", playerEngine.slotB.fps))fps • \(playerEngine.slotB.codec)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(accentSlotB)
                                .lineLimit(1)
                        } else {
                            Text(" ")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.clear)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Slot badges & Quick assignment buttons
            HStack(spacing: 4) {
                if isSlotA {
                    Text("A: MASTER")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .foregroundColor(accentPositive)
                        .studioBox(background: accentPositive.opacity(0.18), border: accentPositive.opacity(0.8))
                } else {
                    Button(action: { playerEngine.loadVideo(url: url, into: .slotA) }) {
                        Text("+A")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .foregroundColor(textMuted)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .explain("Load as Slot A (Master)", binding: $hoverExplanation)
                }
                
                if isSlotB {
                    HStack(spacing: 2) {
                        Text("B: COMPARE")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .foregroundColor(accentSlotB)
                            .studioBox(background: accentSlotB.opacity(0.18), border: accentSlotB.opacity(0.8))
                        
                        Button(action: { playerEngine.clearSlotB() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .frame(width: 14, height: 14)
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                        .explain("Clear Slot B", binding: $hoverExplanation)
                    }
                } else {
                    Button(action: { playerEngine.loadVideo(url: url, into: .slotB) }) {
                        Text("+B")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .foregroundColor(textMuted)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .explain("Load as Slot B (Compare / ⌥+Click)", binding: $hoverExplanation)
                }
            }
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .padding(.leading, 8)
        .studioBox(background: isSelected ? bgSubtle : Color.clear, border: isSelected ? borderLine : Color.clear)
        .contentShape(Rectangle())
        .explain(url.path, binding: $hoverExplanation)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Set as Slot A (Master)") {
                playerEngine.loadVideo(url: url, into: .slotA)
            }
            Button("Set as Slot B (Compare)") {
                playerEngine.loadVideo(url: url, into: .slotB)
            }
            if playerEngine.slotB.url != nil {
                Divider()
                Button("Swap Slot A ⇄ B") {
                    playerEngine.swapSlots()
                }
                Button("Clear Slot B (Single Mode)") {
                    playerEngine.clearSlotB()
                }
            }
            Divider()
            Menu("Tags") {
                ForEach(FinderTagColor.allCases) { tag in
                    Button(action: {
                        toggleFinderTag(tag, for: url)
                    }) {
                        HStack {
                            Text(tag.rawValue)
                            if currentTag == tag {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button(action: {
                    setFinderTag(nil, for: url)
                }) {
                    Text("Remove Tag")
                }
            }
        }
    }
    
    // MARK: - Monitor Header
    
    private var playerMonitorHeader: some View {
        HStack(spacing: 12) {
            if playerEngine.slotB.url != nil {
                Spacer()
                
                // Centered Comparison Controls Toolbar
                PlayerComparisonBar(
                    engine: playerEngine,
                    isLightMode: isLightMode,
                    hoverExplanation: $hoverExplanation
                )
                
                Spacer()
            } else {
                // Single Slot Filename & Specs (100% v0.2.4 appearance)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playerEngine.activeFileName.isEmpty ? "NO ACTIVE ASSET" : playerEngine.activeFileName.uppercased())
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(textMain)
                        .lineLimit(1)
                    
                    if !playerEngine.activeResolution.isEmpty {
                        Text("\(playerEngine.activeResolution) // \(String(format: "%.1f", playerEngine.activeFps)) FPS // \(playerEngine.activeCodec)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                }
                
                Spacer()
            }
        }
    }
    
    // MARK: - Viewport Drop Zone Handler
    
    func handleViewportDrop(providers: [NSItemProvider], location: CGPoint, viewportWidth: CGFloat) -> Bool {
        let target: SlotTarget = (location.x < viewportWidth / 2.0) ? .slotA : .slotB
        return handleDrop(providers: providers, forTab: .player, targetSlot: target)
    }
    
    // MARK: - Timecode Bar (above timeline)
    
    private var playerTimecodeBar: some View {
        ZStack {
            // Center: Shuttle Speed Indicator (Truly centered horizontally, no box, hidden when paused)
            if playerEngine.shuttleStateText != "PAUSE" && (playerEngine.isPlaying || playerEngine.rate != 0) {
                Text(playerEngine.shuttleStateText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(accentPositive)
                    .tracking(0.5)
            }
            
            // Outer Strip: Left Timecode + Zoom, Right Duration
            HStack(spacing: 12) {
                // Left: Current SMPTE Timecode or Frame Count (Fixed 125px width)
                Menu {
                    Button(action: { playerEngine.displayTimeAsFrames = false }) {
                        HStack {
                            Text("SMPTE Timecode (HH:MM:SS:FF)")
                            if !playerEngine.displayTimeAsFrames {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Button(action: { playerEngine.displayTimeAsFrames = true }) {
                        HStack {
                            Text("Frames (Frame Count)")
                            if playerEngine.displayTimeAsFrames {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(playerEngine.displayTimeAsFrames ? "\(playerEngine.currentFrame) frames" : playerEngine.currentTimecode)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(accentPositive)
                            .tracking(0.5)
                            .lineLimit(1)
                        
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(accentPositive.opacity(0.8))
                    }
                    .frame(width: 125, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                // Zoom Dropdown Menu (Fixed 64px width)
                Menu {
                    Button("Fit to Window") { playerEngine.setZoomFit() }
                    Divider()
                    Button("10%") { playerEngine.setZoomLevel(0.10) }
                    Button("25%") { playerEngine.setZoomLevel(0.25) }
                    Button("50%") { playerEngine.setZoomLevel(0.50) }
                    Button("75%") { playerEngine.setZoomLevel(0.75) }
                    Button("100%") { playerEngine.setZoomLevel(1.0) }
                    Button("150%") { playerEngine.setZoomLevel(1.50) }
                    Button("200%") { playerEngine.setZoomLevel(2.0) }
                    Button("400%") { playerEngine.setZoomLevel(4.0) }
                } label: {
                    HStack(spacing: 4) {
                        Text(playerEngine.isFitZoom ? "Fit" : "\(Int(round(playerEngine.zoomScale * 100)))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(textMuted)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: 64, height: 22)
                    .studioBox(background: bgSubtle, border: borderLine)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 64)
                
                Spacer()
                
                // Right: Duration Timecode / Total Frames (Locked 125px width)
                Text(playerEngine.displayTimeAsFrames ? "\(playerEngine.totalFrames) frames" : playerEngine.durationTimecode)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(textMuted)
                    .tracking(0.5)
                    .lineLimit(1)
                    .frame(width: 125, alignment: .trailing)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
    }
    
    // MARK: - Transport Bar
    
    private var playerTransportBar: some View {
        HStack(spacing: 0) {
            // Left: Audio Volume & Mute (Fixed 186px width - matches 186px on right)
            HStack(spacing: 8) {
                let speakerIcon: String = {
                    if playerEngine.isMuted || playerEngine.volume <= 0.001 {
                        return "speaker.slash.fill"
                    } else if playerEngine.volume > 0.66 {
                        return "speaker.wave.3.fill"
                    } else if playerEngine.volume > 0.33 {
                        return "speaker.wave.2.fill"
                    } else {
                        return "speaker.wave.1.fill"
                    }
                }()
                
                Button(action: { playerEngine.isMuted.toggle() }) {
                    Image(systemName: speakerIcon)
                        .font(.system(size: 11))
                        .foregroundColor(playerEngine.isMuted ? alertRed : textMain)
                        .frame(width: 18, height: 18, alignment: .center)
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
                .explain(playerEngine.isMuted ? "Unmute audio" : "Mute audio", binding: $hoverExplanation)
                
                Slider(value: Binding(
                    get: { Double(playerEngine.volume) },
                    set: { playerEngine.volume = Float($0) }
                ), in: 0...1)
                .frame(width: 70)
                .tint(accentPositive)
                .disabled(playerEngine.isMuted)
            }
            .frame(width: 210, alignment: .leading)
            
            Spacer()
            
            // Center: Playback, Shuttle & Frame Controls
            HStack(spacing: 8) {
                // 1. Unified Transport Deck (Tight & Proportional)
                HStack(spacing: 5) {
                    // Slow Rev (Shift + J)
                    transportBtn(icon: "backward", tooltip: "Slow Reverse (⇧J / Tap to accelerate)", size: 13, width: 26) {
                        playerEngine.pressSlowJ()
                    }
                    
                    // Step Back 1 Frame (Left Arrow)
                    transportBtn(icon: "backward.frame.fill", tooltip: "Step Back 1 Frame (Left Arrow)", size: 13, width: 26) {
                        playerEngine.stepFrame(forward: false)
                    }
                    
                    // Shuttle Reverse (J)
                    Button(action: { playerEngine.pressJ() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 28, height: 28)
                            .foregroundColor(playerEngine.rate < 0 ? accentPositive : textMain)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .explain("Shuttle Reverse (J: -1x, -2x, -4x, -8x)", binding: $hoverExplanation)
                    
                    // Play / Pause (Space / K)
                    Button(action: { playerEngine.togglePlayPause() }) {
                        AnimatedPlayPauseIconView(
                            isPlaying: playerEngine.isPlaying,
                            color: textMain,
                            size: 20
                        )
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .explain("Play / Pause (Spacebar / K)", binding: $hoverExplanation)
                    
                    // Shuttle Forward (L)
                    Button(action: { playerEngine.pressL() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 28, height: 28)
                            .foregroundColor(playerEngine.rate > 1.0 ? accentPositive : textMain)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .explain("Shuttle Forward (L: 1x, 2x, 4x, 8x)", binding: $hoverExplanation)
                    
                    // Step Forward 1 Frame (Right Arrow)
                    transportBtn(icon: "forward.frame.fill", tooltip: "Step Forward 1 Frame (Right Arrow)", size: 13, width: 26) {
                        playerEngine.stepFrame(forward: true)
                    }
                    
                    // Slow Forward (Shift + L)
                    transportBtn(icon: "forward", tooltip: "Slow Forward (Shift + L / Tap to accelerate)", size: 13, width: 26) {
                        playerEngine.pressSlowL()
                    }
                }
                
                // Group Divider
                Rectangle()
                    .fill(borderLine.opacity(0.45))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                
                // 2. Playback Utilities: Loop & Crosshair
                HStack(spacing: 4) {
                    transportBtn(
                        icon: "repeat",
                        tooltip: playerEngine.isLooping ? "Loop Playback: ON (⌘L)" : "Loop Playback: OFF (⌘L)",
                        isActive: playerEngine.isLooping,
                        size: 12,
                        width: 26
                    ) {
                        playerEngine.isLooping.toggle()
                    }
                    
                    transportBtn(
                        icon: "plus.viewfinder",
                        tooltip: playerEngine.showCenterCrosshair ? "Center Crosshair: ON" : "Center Crosshair: OFF",
                        isActive: playerEngine.showCenterCrosshair,
                        size: 12,
                        width: 26
                    ) {
                        playerEngine.showCenterCrosshair.toggle()
                    }
                }
                
                // Group Divider
                Rectangle()
                    .fill(borderLine.opacity(0.45))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                
                // 3. Compact Borderless Line Finding Navigation
                let hasGlitches = scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
                HStack(spacing: 3) {
                    Button(action: { jumpToPreviousGlitchFinding() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left.to.line")
                                .font(.system(size: 9, weight: .bold))
                            Text("PREV LINE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .frame(height: 28)
                        .padding(.horizontal, 5)
                        .foregroundColor(hasGlitches ? alertRed : textMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(!hasGlitches)
                    .explain(hasGlitches ? "Jump to previous detected line glitch (⇧N / cycles backwards through findings of Tab 1)." : "No line glitches found in Tab 1 to cycle through.", binding: $hoverExplanation)
                    
                    Button(action: { jumpToNextGlitchFinding() }) {
                        HStack(spacing: 3) {
                            Text("NEXT LINE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                            Image(systemName: "chevron.right.to.line")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .frame(height: 28)
                        .padding(.horizontal, 5)
                        .foregroundColor(hasGlitches ? alertRed : textMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(!hasGlitches)
                    .explain(hasGlitches ? "Jump to next detected line glitch (N / cycles forwards through findings of Tab 1)." : "No line glitches found in Tab 1 to cycle through.", binding: $hoverExplanation)
                }
                
                // Group Divider
                Rectangle()
                    .fill(borderLine.opacity(0.45))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                
                // 4. Finder Tags Button (Border-free)
                let activeURL = playerEngine.activeURL
                let activeTag = activeURL != nil ? fileTagsMap[activeURL!] : nil
                Button(action: {
                    showTagPickerPopover.toggle()
                }) {
                    HStack(spacing: 4) {
                        if let tag = activeTag {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 7, height: 7)
                        } else {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text("TAGS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .frame(height: 28)
                    .padding(.horizontal, 5)
                    .foregroundColor(activeTag != nil ? activeTag!.color : (activeURL == nil ? textMuted : textMain.opacity(0.85)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(activeURL == nil)
                .explain(activeURL != nil ? "Tag current file with native macOS Finder color tags." : "Load a file to apply Finder tags.", binding: $hoverExplanation)
                .popover(isPresented: $showTagPickerPopover, arrowEdge: .top) {
                    tagPickerPopoverView(for: activeURL)
                }
            }
            
            Spacer()
            
            // Right: Screenshot, Review Fullscreen, Video Fullscreen & Shortcuts Menu
            HStack(spacing: 6) {
                // Export Screenshot Button (Border-free)
                Button(action: { exportCurrentFrameScreenshot() }) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain("Export screenshot of the current video frame as medium-quality JPG.", binding: $hoverExplanation)
                
                // Review Fullscreen Button (Border-free)
                Button(action: { enterFullscreen(mode: .review) }) {
                    Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain("Review Fullscreen with HUD & timeline controls (⇧F).", binding: $hoverExplanation)
                
                // Video Fullscreen Button (Clean zero UI, Border-free)
                Button(action: { enterFullscreen(mode: .videoOnly) }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .disabled(playerEngine.activeURL == nil)
                .explain("Clean Video Fullscreen with zero UI (F). Press ESC to exit.", binding: $hoverExplanation)
                
                Button(action: { showShortcutsModal = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "command")
                            .font(.system(size: 9, weight: .bold))
                        Text("SHORTCUTS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                        Image(systemName: "macwindow")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .frame(width: 110, height: 28)
                    .foregroundColor(textMain)
                    .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .explain("View all player keyboard shortcuts in a centered pop-up reference window.", binding: $hoverExplanation)
            }
            .frame(width: 220, alignment: .trailing)
        }
        .frame(height: 28)
    }
    
    private func transportBtn(icon: String, tooltip: String, isActive: Bool = false, size: CGFloat = 14, width: CGFloat = 30, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .bold))
                .frame(width: width, height: 28)
                .foregroundColor(isActive ? accentPositive : textMain)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .explain(tooltip, binding: $hoverExplanation)
    }
    
    var playerTreeNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.buildTree(rootURL: folderURL, files: videoFiles)
    }
    
    var hasPlayerSubfolders: Bool {
        FileSystemTreeBuilder.hasSubfolders(in: playerTreeNodes)
    }
    
    var flattenedPlayerNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(
            nodes: playerTreeNodes,
            collapsedIDs: playerCollapsedFolderIDs,
            hiddenIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders,
            filterText: playerFilterText
        )
    }
    
    var filteredPlayerFiles: [URL] {
        let treeOrder = FileSystemTreeBuilder.orderedVideoURLs(from: playerTreeNodes)
        let baseFiles = treeOrder.isEmpty ? videoFiles : treeOrder
        if playerFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return baseFiles
        }
        return baseFiles.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(playerFilterText) }
    }
    
    func revealPlayerFolderContaining(url: URL) {
        guard !playerCollapsedFolderIDs.isEmpty else { return }
        let targetPath = url.standardizedFileURL.path
        
        var idsToExpand: Set<String> = []
        func checkNode(_ node: FileSystemTreeNode) {
            guard node.isDirectory else { return }
            let dirPath = node.url.standardizedFileURL.path
            let isAncestor = targetPath.hasPrefix(dirPath + "/") || node.videoURLs.contains(where: { $0.standardizedFileURL.path == targetPath })
            if isAncestor {
                idsToExpand.insert(node.id)
                for child in node.children {
                    checkNode(child)
                }
            }
        }
        
        for root in playerTreeNodes {
            checkNode(root)
        }
        
        let intersection = playerCollapsedFolderIDs.intersection(idsToExpand)
        if !intersection.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                playerCollapsedFolderIDs.subtract(intersection)
            }
        }
    }
    
    private func toggleAllPlayerFolders() {
        if playerCollapsedFolderIDs.isEmpty {
            func collectFolderIDs(_ node: FileSystemTreeNode) -> [String] {
                var ids: [String] = []
                if node.isDirectory {
                    ids.append(node.id)
                    for child in node.children {
                        ids.append(contentsOf: collectFolderIDs(child))
                    }
                }
                return ids
            }
            playerCollapsedFolderIDs = Set(playerTreeNodes.flatMap { collectFolderIDs($0) })
        } else {
            playerCollapsedFolderIDs.removeAll()
        }
    }
    
    // MARK: - Screenshot Capture & Export
    
    private func exportCurrentFrameScreenshot() {
        let currentTarget = playerEngine.activeTarget
        let currentSlot: SlotTarget = (currentTarget == .slotB && playerEngine.slotB.url != nil) ? .slotB : .slotA
        guard let url = (currentSlot == .slotA) ? playerEngine.slotA.url : playerEngine.slotB.url else { return }
        
        let baseName = url.deletingPathExtension().lastPathComponent
        let frameNum = (currentSlot == .slotA) ? playerEngine.currentFrame : Int(round(CMTimeGetSeconds(playerEngine.slotB.currentTime) * max(1.0, playerEngine.slotB.fps)))
        let defaultFileName = "\(baseName)_frame_\(frameNum).jpg"
        
        let savePanel = NSSavePanel()
        savePanel.title = "Save Frame Screenshot (\(currentSlot == .slotA ? "Slot A" : "Slot B"))"
        savePanel.prompt = "Save"
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFileName
        savePanel.allowedContentTypes = [.jpeg]
        
        if let parentDir = folderURL {
            savePanel.directoryURL = parentDir
        }
        
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            Task { @MainActor in
                do {
                    try await playerEngine.exportCurrentFrameAsJPEG(for: currentSlot, to: targetURL, quality: 0.65)
                    NSSound(named: "Tink")?.play()
                } catch {
                    print("[Screenshot] Export error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Tag Picker Popover
    
    private func tagPickerPopoverView(for url: URL?) -> some View {
        let currentTag = url != nil ? fileTagsMap[url!] : nil
        return HStack(spacing: 12) {
            ForEach(FinderTagColor.allCases) { tag in
                Button(action: {
                    if let url = url {
                        toggleFinderTag(tag, for: url)
                    }
                    showTagPickerPopover = false
                }) {
                    ZStack {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 20, height: 20)
                            .shadow(color: tag.color.opacity(currentTag == tag ? 0.6 : 0.2), radius: 3, x: 0, y: 1)
                        
                        if currentTag == tag {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(.white)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .explain("Finder Tag: \(tag.rawValue)", binding: $hoverExplanation)
            }
            
            Divider()
                .frame(height: 16)
            
            Button(action: {
                if let url = url {
                    setFinderTag(nil, for: url)
                }
                showTagPickerPopover = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(currentTag != nil ? textMain : textMuted)
            }
            .buttonStyle(.plain)
            .disabled(currentTag == nil)
            .explain("Remove Finder tag", binding: $hoverExplanation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bgPanel)
    }
    
    // MARK: - Fullscreen Video Presentation Overlays
    
    var fullscreenPlayerOverlay: some View {
        FullscreenPlayerView(
            engine: playerEngine,
            scanResults: scanResults,
            videoFiles: videoFiles,
            onExit: { exitFullscreen() },
            onJumpNext: { jumpToNextGlitchFinding() },
            onJumpPrev: { jumpToPreviousGlitchFinding() }
        )
    }
    
    var cleanVideoFullscreenOverlay: some View {
        CleanVideoFullscreenView(
            engine: playerEngine,
            onExit: { exitFullscreen() }
        )
    }
}

// MARK: - Reusable Player Comparison Bar

struct PlayerComparisonBar: View {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool = false
    var hoverExplanation: Binding<String>? = nil
    var onInteraction: (() -> Void)? = nil
    
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private let accentPositive = StudioTheme.positive
    private let accentSlotB = StudioTheme.slotBAccent
    private let alertRed = StudioTheme.negative
    
    var body: some View {
        HStack(spacing: 8) {
            // Group 1: Comparison View Modes (Icons, no boxes)
            HStack(spacing: 4) {
                modeBtn(mode: .single, icon: "rectangle", helpText: "Single Mode: Display Slot A Master video in full viewport.")
                modeBtn(mode: .splitVertical, icon: "rectangle.split.2x1", helpText: "Split Wipe (Vertical): Interactive vertical split divider comparing Slot A and Slot B.")
                modeBtn(mode: .splitHorizontal, icon: "rectangle.split.1x2", helpText: "Split Wipe (Horizontal): Interactive horizontal split divider comparing Slot A and Slot B.")
                modeBtn(mode: .sideBySide, icon: "square.split.2x1", helpText: "Side-by-Side (Horizontal): Scaled dual video comparison side by side (Left: Slot A, Right: Slot B).")
                modeBtn(mode: .sideBySideVertical, icon: "square.split.1x2", helpText: "Side-by-Side (Vertical): Scaled dual video comparison stacked vertically (Top: Slot A, Bottom: Slot B).")
                modeBtn(mode: .difference, icon: "circle.lefthalf.filled", helpText: "Difference Mode: RGB subtraction blend (|A - B|). Identical pixels appear black; discrepancies glow.")
                modeBtn(mode: .overlay, icon: "square.2.layers.3d", helpText: "50% Opacity Overlay: Slot B reference video is overlaid on top of Slot A at 50% opacity.")
            }
            
            Rectangle()
                .fill(borderLine.opacity(0.6))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            
            // Group 2: Rapid Blink (Flicker) Button (Border-free, fixed width to prevent layout jitter)
            Button(action: {
                engine.isBlinkCompareB.toggle()
                onInteraction?()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: engine.isBlinkCompareB ? "eye.fill" : "eye")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 14, alignment: .center)
                    Text("(TAB)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .frame(width: 54, height: 26, alignment: .center)
                .foregroundColor(engine.isBlinkCompareB ? accentSlotB : textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .explain("Rapid Blink / Flicker Compare (Tab): Click or press Tab to rapidly toggle between Slot A and Slot B.", binding: hoverExplanation)
            
            Rectangle()
                .fill(borderLine.opacity(0.6))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            
            // Group 3: Playback Sync & Audio Solo (Icons, no boxes)
            HStack(spacing: 4) {
                // Gang Link Toggle
                Button(action: {
                    engine.isLinked.toggle()
                    onInteraction?()
                }) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundColor(engine.isLinked ? textMain : textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Gang Playhead Link: Lock transport controls and scrubbers between Slot A and Slot B (Currently: \(engine.isLinked ? "ON" : "OFF")).", binding: hoverExplanation)
                
                // Audio Solo Selector
                Button(action: {
                    engine.audioSlot = (engine.audioSlot == .slotA ? .slotB : .slotA)
                    onInteraction?()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(engine.audioSlot == .slotA ? "A" : "B")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 4)
                    .foregroundColor(engine.audioSlot == .slotA ? accentPositive : accentSlotB)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Solo Audio Output: Playing audio from Slot \(engine.audioSlot == .slotA ? "A (Master)" : "B (Compare)"). Click to switch.", binding: hoverExplanation)
            }
            
            Rectangle()
                .fill(borderLine.opacity(0.6))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            
            // Group 4: Slot Operations (Swap / Toggle Clip Names / Clear, Border-free)
            HStack(spacing: 4) {
                // Swap Button (Grey icon)
                Button(action: {
                    engine.swapSlots()
                    onInteraction?()
                }) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundColor(textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Swap Slots (X): Swap Slot A (Master) and Slot B (Compare).", binding: hoverExplanation)
                
                // Show/Hide Deliverable Clip Names on Canvas (Next to SWAP, before CLEAR B)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        engine.showClipNamesOverlay.toggle()
                    }
                    onInteraction?()
                }) {
                    Image(systemName: "character.textbox")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundColor(engine.showClipNamesOverlay ? textMain : textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain(engine.showClipNamesOverlay ? "Hide Clip Names: Hide deliverable names overlay on canvas." : "Show Clip Names: Display deliverable names overlay on canvas.", binding: hoverExplanation)
                
                // Clear B Button
                Button(action: {
                    engine.clearSlotB()
                    onInteraction?()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("CLEAR B")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 4)
                    .foregroundColor(alertRed)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Clear Slot B: Close comparison video and return to single-video mode.", binding: hoverExplanation)
            }
        }
    }
    
    private func modeBtn(mode: CompareMode, icon: String, helpText: String) -> some View {
        let isActive = engine.compareMode == mode
        return Button(action: {
            engine.compareMode = mode
            onInteraction?()
        }) {
            modeIconView(mode: mode, icon: icon, isActive: isActive)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .explain(helpText, binding: hoverExplanation)
    }
    
    @ViewBuilder
    private func modeIconView(mode: CompareMode, icon: String, isActive: Bool) -> some View {
        if !isActive {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(textMuted)
        } else {
            switch mode {
            case .single:
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundColor(accentPositive)
            case .splitVertical, .sideBySide:
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: accentPositive, location: 0.0),
                                .init(color: accentPositive, location: 0.49),
                                .init(color: accentSlotB, location: 0.51),
                                .init(color: accentSlotB, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            case .splitHorizontal, .sideBySideVertical:
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: accentPositive, location: 0.0),
                                .init(color: accentPositive, location: 0.49),
                                .init(color: accentSlotB, location: 0.51),
                                .init(color: accentSlotB, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            case .difference:
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: accentPositive, location: 0.0),
                                .init(color: accentPositive, location: 0.49),
                                .init(color: accentSlotB, location: 0.51),
                                .init(color: accentSlotB, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            case .overlay:
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: accentSlotB, location: 0.0),
                                .init(color: accentSlotB, location: 0.49),
                                .init(color: accentPositive, location: 0.51),
                                .init(color: accentPositive, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }
}

// MARK: - Dedicated Studio Fullscreen Player View

struct FullscreenPlayerView: View {
    @ObservedObject var engine: PlayerEngine
    var scanResults: [VideoQCResult]
    var videoFiles: [URL] = []
    var onExit: () -> Void
    var onJumpNext: () -> Void
    var onJumpPrev: () -> Void
    
    @State private var showControls: Bool = true
    @State private var isHoveringControls: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil
    
    private let accentPositive = StudioTheme.positive
    private let accentSlotB = StudioTheme.slotBAccent
    private let alertRed = StudioTheme.negative
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            // Fullscreen Video Viewport
            if engine.activeURL != nil {
                VideoViewportView(
                    engine: engine,
                    isLightMode: false,
                    allowScrollZoom: true,
                    onSingleClick: {
                        engine.togglePlayPause()
                        userDidInteract()
                    },
                    onDoubleClick: {
                        onExit()
                    }
                )
                .ignoresSafeArea()
            }
            
            // Floating Overlay Controls
            if showControls {
                VStack(spacing: 0) {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    
                    if engine.slotB.url != nil && engine.showClipNamesOverlay {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text("A:")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundColor(accentPositive)
                                    Text(engine.slotA.fileName.isEmpty ? "--" : engine.slotA.fileName.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                HStack(spacing: 5) {
                                    Text("B:")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundColor(accentSlotB)
                                    Text(engine.slotB.fileName.isEmpty ? "--" : engine.slotB.fileName.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.70))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .padding(.leading, 16)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                            
                            Spacer()
                        }
                    }
                    
                    Spacer()
                    
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                userDidInteract()
            case .ended:
                break
            }
        }
        .onAppear {
            userDidInteract()
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }
    
    private func userDidInteract() {
        if !showControls {
            withAnimation(.easeInOut(duration: 0.15)) {
                showControls = true
            }
        }
        
        hideTask?.cancel()
        if engine.isPlaying && !isHoveringControls {
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled && engine.isPlaying && !isHoveringControls {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls = false
                    }
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            if engine.slotB.url != nil {
                Spacer()
                
                // Centered Comparison Controls Toolbar
                PlayerComparisonBar(
                    engine: engine,
                    isLightMode: false,
                    onInteraction: { userDidInteract() }
                )
                
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.activeFileName.isEmpty ? "NO ACTIVE ASSET" : engine.activeFileName.uppercased())
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    if !engine.activeResolution.isEmpty {
                        Text("\(engine.activeResolution) // \(String(format: "%.1f", engine.activeFps)) FPS // \(engine.activeCodec)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                    }
                }
                
                Spacer()
                
                // Compare B selector in Fullscreen
                Menu {
                    let candidateFiles = videoFiles.filter { $0 != engine.slotA.url }
                    if !candidateFiles.isEmpty {
                        Section("Queue Deliverables") {
                            ForEach(candidateFiles, id: \.self) { file in
                                Button(file.lastPathComponent) {
                                    engine.loadVideo(url: file, into: .slotB)
                                    userDidInteract()
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Open Compare File from Disk...") {
                        openCompareFileInFullscreen()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 10, weight: .bold))
                        Text("[ + COMPARE (B) ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.15).opacity(0.85))
                    .foregroundColor(accentSlotB)
                    .border(accentSlotB.opacity(0.6), width: 1)
                }
                .buttonStyle(.plain)
                .help("Select a clip to compare side-by-side with current video in Slot B")
                
                Spacer()
            }
            
            Button(action: onExit) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("[ EXIT FULLSCREEN (ESC) ]")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.15).opacity(0.85))
                .foregroundColor(.white)
                .border(Color(white: 0.35), width: 1)
            }
            .buttonStyle(.plain)
            .help("Exit Fullscreen (ESC / F)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onHover { isHovering in
            isHoveringControls = isHovering
            if isHovering { userDidInteract() }
        }
    }
    
    private func openCompareFileInFullscreen() {
        let panel = NSOpenPanel()
        panel.title = "Select Video to Compare (Slot B)"
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadVideo(url: url, into: .slotB)
            userDidInteract()
        }
    }
    
    // MARK: - Bottom Control Bar
    
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Timeline Scrubber
            TimelineScrubberView(engine: engine, isLightMode: false)
                .frame(height: 46)
            
            // Transport & Timecode Bar
            HStack(spacing: 12) {
                // Left: Timecode / Frame Count + Shuttle Speed (Fixed 280px width)
                HStack(spacing: 8) {
                    Text(engine.displayTimeAsFrames ? "\(engine.currentFrame) frames" : engine.currentTimecode)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(accentPositive)
                        .frame(width: 120, alignment: .leading)
                    
                    if engine.shuttleStateText != "PAUSE" && (engine.isPlaying || engine.rate != 0) {
                        Text(engine.shuttleStateText)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(accentPositive)
                            .tracking(0.5)
                    }
                }
                .frame(width: 280, alignment: .leading)
                
                Spacer()
                
                // Center: Transport Buttons
                HStack(spacing: 8) {
                    // 1. Unified Transport Deck (Tight & Proportional)
                    HStack(spacing: 5) {
                        transportBtn(icon: "backward", tooltip: "Slow Reverse (Shift + J)", size: 13, width: 26) {
                            engine.pressSlowJ()
                        }
                        transportBtn(icon: "backward.frame.fill", tooltip: "Step -1 Frame (Left Arrow)", size: 13, width: 26) {
                            engine.stepFrame(forward: false)
                        }
                        
                        Button(action: { engine.pressJ() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 28, height: 28)
                                .foregroundColor(engine.rate < 0 ? accentPositive : .white)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .help("Shuttle Reverse (J)")
                        
                        Button(action: { engine.togglePlayPause() }) {
                            AnimatedPlayPauseIconView(
                                isPlaying: engine.isPlaying,
                                color: .white,
                                size: 20
                            )
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .help("Play / Pause (Spacebar / K)")
                        
                        Button(action: { engine.pressL() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 28, height: 28)
                                .foregroundColor(engine.rate > 1.0 ? accentPositive : .white)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .help("Shuttle Forward (L)")
                        
                        transportBtn(icon: "forward.frame.fill", tooltip: "Step +1 Frame (Right Arrow)", size: 13, width: 26) {
                            engine.stepFrame(forward: true)
                        }
                        transportBtn(icon: "forward", tooltip: "Slow Forward (Shift + L)", size: 13, width: 26) {
                            engine.pressSlowL()
                        }
                    }
                    
                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 2)
                    
                    // 2. Playback Utilities
                    HStack(spacing: 4) {
                        transportBtn(icon: "repeat", tooltip: "Loop Playback (⌘L)", isActive: engine.isLooping, size: 12, width: 26) {
                            engine.isLooping.toggle()
                        }
                        transportBtn(icon: "plus.viewfinder", tooltip: "Center Crosshair", isActive: engine.showCenterCrosshair, size: 12, width: 26) {
                            engine.showCenterCrosshair.toggle()
                        }
                    }
                    
                    let hasGlitches = scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
                    if hasGlitches {
                        // Divider
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: 14)
                            .padding(.horizontal, 2)
                        
                        // 3. Compact Borderless Glitch Findings Navigation
                        HStack(spacing: 3) {
                            Button(action: onJumpPrev) {
                                HStack(spacing: 3) {
                                    Image(systemName: "chevron.left.to.line")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("PREV LINE")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .frame(height: 28)
                                .padding(.horizontal, 5)
                                .foregroundColor(alertRed)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(TransportIconButtonStyle())
                            .help("Previous Glitch (⇧N)")
                            
                            Button(action: onJumpNext) {
                                HStack(spacing: 3) {
                                    Text("NEXT LINE")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    Image(systemName: "chevron.right.to.line")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .frame(height: 28)
                                .padding(.horizontal, 5)
                                .foregroundColor(alertRed)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(TransportIconButtonStyle())
                            .help("Next Glitch (N)")
                        }
                    }
                }
                
                Spacer()
                
                // Right: Duration Timecode & Exit Fullscreen Button (Fixed 280px width)
                HStack(spacing: 12) {
                    Text(engine.displayTimeAsFrames ? "\(engine.totalFrames) frames" : engine.durationTimecode)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(Color(white: 0.6))
                        .frame(width: 120, alignment: .trailing)
                    
                    Button(action: onExit) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 32, height: 30)
                            .foregroundColor(.white)
                            .studioBox(background: Color(white: 0.15), border: Color(white: 0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Exit Fullscreen (ESC / F)")
                }
                .frame(width: 280, alignment: .trailing)
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onHover { isHovering in
            isHoveringControls = isHovering
            if isHovering { userDidInteract() }
        }
    }
    
    private func transportBtn(icon: String, tooltip: String, isActive: Bool = false, size: CGFloat = 14, width: CGFloat = 30, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .bold))
                .frame(width: width, height: 28)
                .foregroundColor(isActive ? accentPositive : .white)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .help(tooltip)
    }
}

// MARK: - Pure Video Fullscreen View (Zero UI)

struct CleanVideoFullscreenView: View {
    @ObservedObject var engine: PlayerEngine
    var onExit: () -> Void
    
    @State private var hideCursorTask: Task<Void, Never>? = nil
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            if engine.activeURL != nil {
                VideoViewportView(
                    engine: engine,
                    isLightMode: false,
                    allowScrollZoom: false,
                    onSingleClick: {
                        engine.togglePlayPause()
                    },
                    onDoubleClick: {
                        onExit()
                    }
                )
                .ignoresSafeArea()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                resetCursorTimer()
            case .ended:
                break
            }
        }
        .onAppear {
            engine.setZoomFit()
            resetCursorTimer()
        }
        .onDisappear {
            hideCursorTask?.cancel()
        }
    }
    
    private func resetCursorTimer() {
        hideCursorTask?.cancel()
        if engine.isPlaying {
            hideCursorTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled && engine.isPlaying {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }
}

