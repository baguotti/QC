import SwiftUI
import AVFoundation
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 4: PREMIERE-STYLE PLAYER ====================
    
    var playerTabView: some View {
        HSplitView {
            // MARK: - Left Panel: Video Queue & Explorer
            VStack(alignment: .leading, spacing: 18) {
                // Asset Picker Section
                deliveryAssetsSection(forTab: .player)
                
                // Search Filter
                if !videoFiles.isEmpty {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        TextField("FILTER ASSETS...", text: $playerFilterText)
                            .font(.system(size: 11, design: .monospaced))
                            .textFieldStyle(.plain)
                            .foregroundColor(textMain)
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
                    .background(bgSubtle)
                    .border(borderLine, width: 1)
                }
                
                // Asset List
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("QUEUE (\(filteredPlayerFiles.count))")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(textMuted)
                        Spacer()
                        if playerEngine.activeURL != nil {
                            Text("ACTIVE: \(playerEngine.activeFileName)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(accentPositive)
                                .lineLimit(1)
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
                        .background(bgCardSubtle)
                        .border(borderLine, width: 1)
                    } else {
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(filteredPlayerFiles, id: \.self) { url in
                                        playerFileRow(url: url)
                                            .id(url)
                                    }
                                }
                            }
                            .onChange(of: playerEngine.activeURL) { _, newURL in
                                if let newURL = newURL {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        scrollProxy.scrollTo(newURL, anchor: .center)
                                    }
                                }
                            }
                        }
                        .background(bgCardSubtle)
                        .border(borderLine, width: 1)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(22)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            
            // MARK: - Right Panel: Program Monitor & Timeline
            VStack(spacing: 0) {
                // Monitor Header Bar
                playerMonitorHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(bgCardHeader)
                    .border(borderLine, width: 1)
                
                // Program Monitor Viewport Canvas
                ZStack {
                    if playerEngine.activeURL != nil {
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .border(borderLine, width: 1)
                
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
                .padding(12)
                .frame(height: 138)
                .background(bgPanel)
                .border(borderLine, width: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Automatically select first file if none loaded
            if playerEngine.activeURL == nil, let first = videoFiles.first {
                playerEngine.loadVideo(url: first)
            }
        }
    }
    
    // MARK: - File Row
    
    private func playerFileRow(url: URL) -> some View {
        let isSelected = playerEngine.activeURL == url
        let currentTag = fileTagsMap[url]
        
        return Button(action: {
            playerEngine.loadVideo(url: url)
        }) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(isSelected ? accentPositive : Color.clear)
                    .frame(width: 3)
                
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? accentPositive : textMuted)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let tag = currentTag {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 7, height: 7)
                        }
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: isSelected ? .black : .medium, design: .monospaced))
                            .foregroundColor(isSelected ? textMain : textSubtle)
                            .lineLimit(1)
                    }
                    
                    // Always reserve space for the metadata line so row height stays constant
                    Text(isSelected && !playerEngine.activeResolution.isEmpty
                         ? "\(playerEngine.activeResolution) • \(String(format: "%.1f", playerEngine.activeFps))fps • \(playerEngine.activeCodec)"
                         : " ")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? accentPositive : .clear)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if isSelected {
                    Text("PLAYING")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(accentPositive.opacity(0.2))
                        .foregroundColor(accentPositive)
                        .border(accentPositive, width: 1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .padding(.horizontal, 8)
            .background(isSelected ? bgSubtle : Color.clear)
            .border(isSelected ? borderLine : Color.clear, width: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
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
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
    
    // MARK: - Monitor Header
    
    private var playerMonitorHeader: some View {
        HStack(spacing: 14) {
            // Filename & Specs
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
            
            // Fullscreen Buttons (Review with HUD & Clean Video Only)
            HStack(spacing: 8) {
                Button(action: { enterFullscreen(mode: .review) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                            .font(.system(size: 10, weight: .bold))
                        Text("[ REVIEW FULLSCREEN ]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(playerEngine.activeURL == nil ? bgSubtle : bgPanel)
                    .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(playerEngine.activeURL == nil)
                .explain("Fullscreen player with on-screen review HUD & timeline controls (⇧F).", binding: $hoverExplanation)
                
                Button(action: { enterFullscreen(mode: .videoOnly) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("[ VIDEO FULLSCREEN ]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(playerEngine.activeURL == nil ? bgSubtle : primaryBtnBg)
                    .foregroundColor(playerEngine.activeURL == nil ? textMuted : primaryBtnFg)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(playerEngine.activeURL == nil)
                .explain("Clean full screen video presentation with zero UI (F). Press ESC to exit.", binding: $hoverExplanation)
            }
        }
    }
    
    // MARK: - Timecode Bar (above timeline)
    
    private var playerTimecodeBar: some View {
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
                Button("10% (Zoom Out)") { playerEngine.setZoomLevel(0.10) }
                Button("25% (Zoom Out)") { playerEngine.setZoomLevel(0.25) }
                Button("50% (Zoom Out)") { playerEngine.setZoomLevel(0.50) }
                Button("75%") { playerEngine.setZoomLevel(0.75) }
                Button("100% (1:1 Pixels)") { playerEngine.setZoomLevel(1.0) }
                Button("150%") { playerEngine.setZoomLevel(1.50) }
                Button("200% (Zoom In)") { playerEngine.setZoomLevel(2.0) }
                Button("400% (Zoom In)") { playerEngine.setZoomLevel(4.0) }
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
                .background(bgSubtle)
                .border(borderLine, width: 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 64)
            
            Spacer()
            
            // Center: Shuttle Speed Indicator (Fixed 100px container so showing/hiding NEVER shifts UI)
            HStack {
                if playerEngine.isPlaying || playerEngine.rate != 0 {
                    Text(playerEngine.shuttleStateText)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(accentPositive.opacity(0.15))
                        .foregroundColor(accentPositive)
                        .border(accentPositive.opacity(0.6), width: 0.5)
                }
            }
            .frame(width: 100, height: 20, alignment: .center)
            
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
        .frame(height: 24)
        .padding(.horizontal, 4)
    }
    
    // MARK: - Transport Bar
    
    private var playerTransportBar: some View {
        HStack(spacing: 0) {
            // Left: Audio Volume & Mute (Fixed 186px width - matches 186px on right)
            HStack(spacing: 8) {
                Button(action: { playerEngine.isMuted.toggle() }) {
                    Image(systemName: playerEngine.isMuted ? "speaker.slash.fill" : (playerEngine.volume > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                        .font(.system(size: 11))
                        .foregroundColor(playerEngine.isMuted ? alertRed : textMain)
                }
                .buttonStyle(.plain)
                .explain(playerEngine.isMuted ? "Unmute audio" : "Mute audio", binding: $hoverExplanation)
                
                Slider(value: Binding(
                    get: { Double(playerEngine.volume) },
                    set: { playerEngine.volume = Float($0) }
                ), in: 0...1)
                .frame(width: 70)
                .tint(accentPositive)
                .disabled(playerEngine.isMuted)
            }
            .frame(width: 186, alignment: .leading)
            
            Spacer()
            
            // Center: Playback, Shuttle & Frame Controls
            HStack(spacing: 5) {
                // Slow Frame-by-Frame Reverse (Shift + J)
                transportBtn(icon: "backward.circle.fill", tooltip: "Slow Frame-by-Frame Reverse (Shift + J / Tap to accelerate)") {
                    playerEngine.pressSlowJ()
                }
                
                // Shuttle Reverse (J)
                transportBtn(icon: "backward.fill", tooltip: "Shuttle Reverse (J: -1x, -2x, -4x, -8x)") {
                    playerEngine.pressJ()
                }
                
                // Step -1 Frame
                transportBtn(icon: "backward.frame.fill", tooltip: "Step Back 1 Frame (Left Arrow)") {
                    playerEngine.stepFrame(forward: false)
                }
                
                // Play / Pause (Space / K)
                Button(action: { playerEngine.togglePlayPause() }) {
                    HStack {
                        Image(systemName: playerEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .black))
                    }
                    .frame(width: 44, height: 28)
                    .background(primaryBtnBg)
                    .foregroundColor(primaryBtnFg)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .explain("Play / Pause (Spacebar / K)", binding: $hoverExplanation)
                
                // Step +1 Frame
                transportBtn(icon: "forward.frame.fill", tooltip: "Step Forward 1 Frame (Right Arrow)") {
                    playerEngine.stepFrame(forward: true)
                }
                
                // Shuttle Forward (L)
                transportBtn(icon: "forward.fill", tooltip: "Shuttle Forward (L: 1x, 2x, 4x, 8x)") {
                    playerEngine.pressL()
                }
                
                // Slow Frame-by-Frame Forward (Shift + L)
                transportBtn(icon: "forward.circle.fill", tooltip: "Slow Frame-by-Frame Forward (Shift + L / Tap to accelerate)") {
                    playerEngine.pressSlowL()
                }
                
                // Loop Playback Toggle (Icon only, no text)
                transportBtn(
                    icon: "repeat",
                    tooltip: playerEngine.isLooping ? "Loop Playback: ON (⌘L)" : "Loop Playback: OFF (⌘L)",
                    isActive: playerEngine.isLooping
                ) {
                    playerEngine.isLooping.toggle()
                }
                
                // Center Crosshair Overlay Toggle (Icon only, no text)
                transportBtn(
                    icon: "plus.viewfinder",
                    tooltip: playerEngine.showCenterCrosshair ? "Center Crosshair: ON" : "Center Crosshair: OFF",
                    isActive: playerEngine.showCenterCrosshair
                ) {
                    playerEngine.showCenterCrosshair.toggle()
                }
                
                let hasGlitches = scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
                
                // Jump to Previous Line Finding Button (Cycles backwards through Tab 1 findings - Fixed 96px width)
                Button(action: {
                    jumpToPreviousGlitchFinding()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.to.line")
                            .font(.system(size: 9, weight: .bold))
                        Text("PREV LINE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 96, height: 28)
                    .background(hasGlitches ? alertRed.opacity(0.18) : bgSubtle)
                    .foregroundColor(hasGlitches ? alertRed : textMuted)
                    .border(hasGlitches ? alertRed.opacity(0.6) : borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(!hasGlitches)
                .explain(hasGlitches ? "Jump to previous detected line glitch (⇧N / cycles backwards through findings of Tab 1)." : "No line glitches found in Tab 1 to cycle through.", binding: $hoverExplanation)
                
                // Jump to Next Line Finding Button (Cycles through Tab 1 findings - Fixed 96px width)
                Button(action: {
                    jumpToNextGlitchFinding()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right.to.line")
                            .font(.system(size: 9, weight: .bold))
                        Text("NEXT LINE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 96, height: 28)
                    .background(hasGlitches ? alertRed.opacity(0.18) : bgSubtle)
                    .foregroundColor(hasGlitches ? alertRed : textMuted)
                    .border(hasGlitches ? alertRed.opacity(0.6) : borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(!hasGlitches)
                .explain(hasGlitches ? "Jump to next detected line glitch (N / cycles forwards through findings of Tab 1)." : "No line glitches found in Tab 1 to cycle through.", binding: $hoverExplanation)
                
                // Finder Tags Button (Fixed 78px width)
                let activeURL = playerEngine.activeURL
                let activeTag = activeURL != nil ? fileTagsMap[activeURL!] : nil
                Button(action: {
                    showTagPickerPopover.toggle()
                }) {
                    HStack(spacing: 5) {
                        if let tag = activeTag {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 8, height: 8)
                        } else {
                            Image(systemName: "tag")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text("TAGS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .frame(width: 78, height: 28)
                    .background(activeTag != nil ? activeTag!.color.opacity(0.18) : bgSubtle)
                    .foregroundColor(activeTag != nil ? activeTag!.color : textMain)
                    .border(activeTag != nil ? activeTag!.color.opacity(0.6) : borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(activeURL == nil)
                .explain(activeURL != nil ? "Tag current file with native macOS Finder color tags." : "Load a file to apply Finder tags.", binding: $hoverExplanation)
                .popover(isPresented: $showTagPickerPopover, arrowEdge: .top) {
                    tagPickerPopoverView(for: activeURL)
                }
            }
            
            Spacer()
            
            // Right: Review Fullscreen, Video Fullscreen & Shortcuts Menu (Fixed 186px width)
            HStack(spacing: 6) {
                // Review Fullscreen Button
                Button(action: { enterFullscreen(mode: .review) }) {
                    Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(bgSubtle)
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(playerEngine.activeURL == nil)
                .explain("Review Fullscreen with HUD & timeline controls (⇧F).", binding: $hoverExplanation)
                
                // Video Fullscreen Button (Clean zero UI)
                Button(action: { enterFullscreen(mode: .videoOnly) }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(bgSubtle)
                        .foregroundColor(playerEngine.activeURL == nil ? textMuted : textMain)
                        .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(playerEngine.activeURL == nil)
                .explain("Clean Video Fullscreen with zero UI (F). Press ESC to exit.", binding: $hoverExplanation)
                
                Menu {
                    Text("KEYBOARD SHORTCUTS")
                    Divider()
                    Button("Spacebar: Play / Pause") {}
                    Button("F: Toggle Video Fullscreen (Clean)") {}
                    Button("⇧ + F: Review Fullscreen (with HUD)") {}
                    Button("ESC: Exit Fullscreen") {}
                    Button("J / K / L: Shuttle Playback (-16x to 16x)") {}
                    Button("⇧ + J / L: Slow Frame-by-Frame") {}
                    Button("← / →: Step 1 Frame") {}
                    Button("⇧ + ← / →: Jump 1 Second") {}
                    Button("↑ / ↓: Previous / Next Deliverable") {}
                    Button("Mouse Wheel: Canvas Zoom (10% - 400%)") {}
                    Button("Drag Canvas: Pan Viewport Hand Tool") {}
                    Button("⌘L: Toggle Seamless Loop") {}
                    Button("N: Jump to Next Line Finding") {}
                    Button("⇧ + N: Jump to Previous Line Finding") {}
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "command")
                            .font(.system(size: 9, weight: .bold))
                        Text("SHORTCUTS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .frame(width: 110, height: 28)
                    .background(bgSubtle)
                    .foregroundColor(textMain)
                    .border(borderLine, width: 1)
                }
                .menuStyle(.borderlessButton)
                .explain("View all player keyboard shortcuts.", binding: $hoverExplanation)
            }
            .frame(width: 186, alignment: .trailing)
        }
        .frame(height: 28)
    }
    
    private func transportBtn(icon: String, tooltip: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 30, height: 28)
                .background(isActive ? accentPositive.opacity(0.18) : bgSubtle)
                .foregroundColor(isActive ? accentPositive : textMain)
                .border(isActive ? accentPositive : borderLine, width: 1)
        }
        .buttonStyle(.plain)
        .explain(tooltip, binding: $hoverExplanation)
    }
    
    var filteredPlayerFiles: [URL] {
        if playerFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return videoFiles
        }
        return videoFiles.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(playerFilterText) }
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

// MARK: - Dedicated Studio Fullscreen Player View

struct FullscreenPlayerView: View {
    @ObservedObject var engine: PlayerEngine
    var scanResults: [VideoQCResult]
    var onExit: () -> Void
    var onJumpNext: () -> Void
    var onJumpPrev: () -> Void
    
    @State private var showControls: Bool = true
    @State private var isHoveringControls: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil
    
    private let accentPositive = StudioTheme.positive
    private let alertRed = StudioTheme.negative
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            // Fullscreen Video Viewport
            if engine.activeURL != nil {
                VideoViewportView(engine: engine, isLightMode: false)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) {
                        onExit()
                    }
                    .onTapGesture(count: 1) {
                        engine.togglePlayPause()
                        userDidInteract()
                    }
            }
            
            // Floating Overlay Controls
            if showControls {
                VStack(spacing: 0) {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    
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
    
    // MARK: - Bottom Control Bar
    
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Timeline Scrubber
            TimelineScrubberView(engine: engine, isLightMode: false)
                .frame(height: 46)
            
            // Transport & Timecode Bar
            HStack(spacing: 12) {
                // Left: Timecode / Frame Count + Shuttle Speed (Fixed 230px width)
                HStack(spacing: 8) {
                    Text(engine.displayTimeAsFrames ? "\(engine.currentFrame) frames" : engine.currentTimecode)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(accentPositive)
                        .frame(width: 130, alignment: .leading)
                    
                    HStack {
                        if engine.isPlaying || engine.rate != 0 {
                            Text(engine.shuttleStateText)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .frame(height: 20)
                                .background(accentPositive.opacity(0.2))
                                .foregroundColor(accentPositive)
                                .border(accentPositive.opacity(0.6), width: 0.5)
                        }
                    }
                    .frame(width: 90, height: 20, alignment: .leading)
                }
                .frame(width: 230, alignment: .leading)
                
                Spacer()
                
                // Center: Transport Buttons
                HStack(spacing: 5) {
                    transportBtn(icon: "backward.circle.fill", tooltip: "Slow Reverse (Shift + J)") {
                        engine.pressSlowJ()
                    }
                    transportBtn(icon: "backward.fill", tooltip: "Shuttle Reverse (J)") {
                        engine.pressJ()
                    }
                    transportBtn(icon: "backward.frame.fill", tooltip: "Step -1 Frame (Left Arrow)") {
                        engine.stepFrame(forward: false)
                    }
                    
                    // Play / Pause
                    Button(action: { engine.togglePlayPause() }) {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .black))
                            .frame(width: 48, height: 30)
                            .background(Color.white)
                            .foregroundColor(.black)
                            .border(Color(white: 0.5), width: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Play / Pause (Spacebar / K)")
                    
                    transportBtn(icon: "forward.frame.fill", tooltip: "Step +1 Frame (Right Arrow)") {
                        engine.stepFrame(forward: true)
                    }
                    transportBtn(icon: "forward.fill", tooltip: "Shuttle Forward (L)") {
                        engine.pressL()
                    }
                    transportBtn(icon: "forward.circle.fill", tooltip: "Slow Forward (Shift + L)") {
                        engine.pressSlowL()
                    }
                    transportBtn(icon: "repeat", tooltip: "Loop Playback (⌘L)", isActive: engine.isLooping) {
                        engine.isLooping.toggle()
                    }
                    transportBtn(icon: "plus.viewfinder", tooltip: "Center Crosshair", isActive: engine.showCenterCrosshair) {
                        engine.showCenterCrosshair.toggle()
                    }
                    
                    let hasGlitches = scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
                    if hasGlitches {
                        Button(action: onJumpPrev) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left.to.line")
                                    .font(.system(size: 9, weight: .bold))
                                Text("PREV LINE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .frame(width: 96, height: 30)
                            .background(alertRed.opacity(0.2))
                            .foregroundColor(alertRed)
                            .border(alertRed.opacity(0.6), width: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Previous Glitch (⇧N)")
                        
                        Button(action: onJumpNext) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right.to.line")
                                    .font(.system(size: 9, weight: .bold))
                                Text("NEXT LINE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .frame(width: 96, height: 30)
                            .background(alertRed.opacity(0.2))
                            .foregroundColor(alertRed)
                            .border(alertRed.opacity(0.6), width: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Next Glitch (N)")
                    }
                }
                
                Spacer()
                
                // Right: Duration Timecode & Exit Fullscreen Button (Fixed 230px width)
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
                            .background(Color(white: 0.15))
                            .foregroundColor(.white)
                            .border(Color(white: 0.35), width: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Exit Fullscreen (ESC / F)")
                }
                .frame(width: 230, alignment: .trailing)
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
    
    private func transportBtn(icon: String, tooltip: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 32, height: 30)
                .background(isActive ? accentPositive.opacity(0.25) : Color(white: 0.15))
                .foregroundColor(isActive ? accentPositive : .white)
                .border(isActive ? accentPositive : Color(white: 0.35), width: 1)
        }
        .buttonStyle(.plain)
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
                VideoViewportView(engine: engine, isLightMode: false, allowScrollZoom: false)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) {
                        onExit()
                    }
                    .onTapGesture(count: 1) {
                        engine.togglePlayPause()
                    }
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

