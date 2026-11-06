import SwiftUI
import UniformTypeIdentifiers
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 2: SPECS ====================
    
    var deliverablesTabView: some View {
        HStack(spacing: 0) {
            // Left Control Panel
            if showSpecsControlPanel {
                ResizableSidePanel(widthKey: "inspectPanelWidth", edge: .trailing, range: 300...640, defaultWidth: 380,
                                   isLightMode: isLightMode,
                                   help: "Drag to resize the panel. Double-click to reset (380 pt).") {
                VStack(alignment: .leading, spacing: 18) {
                    // Unified Asset Picker
                    deliveryAssetsSection(forTab: .specs)
                    
                    // Search Filter (like in Tab 1)
                    if !specsState.deliverableAssets.isEmpty {
                        specsSearchFilterBar
                    }
                    
                    // 02 SPECS ACTIONS: View controls, Audit & Exports
                    specsActionsSection
                    
                    Spacer(minLength: 0)

                    // The selected file at a glance (play / scrub only; can pop out into its own window).
                    if !specsState.deliverableAssets.isEmpty {
                        InspectPreviewPanel(placement: .panel, isLightMode: isLightMode)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgPanel)
                .overlay(
                    Rectangle()
                        .fill(borderLine)
                        .frame(width: 1),
                    alignment: .trailing
                )
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            
            // Right Panel: Specs Table / Stats
            VStack(alignment: .leading, spacing: 0) {
                // Specs Header Bar with Sleeve Toggle
                HStack(spacing: 12) {
                    SleeveToggle(side: .leading, isOpen: showSpecsControlPanel, isLightMode: isLightMode,
                                 help: showSpecsControlPanel ? "Hide Specs Control Panel (⌘⇧←)." : "Reveal Specs Control Panel (⌘⇧←).") {
                        showSpecsControlPanel.toggle()
                    }
                    
                    Text("Specs Audit")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                    
                    Spacer()

                    if !showInspectPlan {
                        SleeveToggle(side: .trailing, isOpen: false, isLightMode: isLightMode,
                                     help: "Reveal the Delivery Plan (⌘⇧→).") {
                            showInspectPlan = true
                        }
                    }
                }
                .headerBand(palette)
                
                if specsState.isInspectingDeliverables {
                    VStack(alignment: .center, spacing: 12) {
                        Spacer()
                        Text("Inspecting deliverables specs...")
                            .font(.ui(size: 15, weight: .semibold))
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                } else if specsState.deliverableAssets.isEmpty {
                    emptyDeliverablesStateView
                } else {
                    deliverablesResultsView
                }
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bgMain)
            .sheet(isPresented: $specsState.showSubtitleCrossCheck) {
                if let report = specsState.subtitleCrossCheck {
                    SubtitleCrossCheckSheet(
                        report: report,
                        isLightMode: isLightMode,
                        onChange: { specsState.subtitleCrossCheck = $0 },
                        onOpen: { video, seconds in
                            specsState.showSubtitleCrossCheck = false
                            openSubtitleDifference(video: video, seconds: seconds)
                        },
                        onClose: { specsState.showSubtitleCrossCheck = false }
                    )
                }
            }

            // Right drawer: the Delivery Plan (it can also pop out into its own window).
            if showInspectPlan {
                InspectPlanDrawer(isLightMode: isLightMode, onClose: { showInspectPlan = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Inspect shows plan status per file, so the plan is kept current while this tab is open (cheap: a change
        // check every 10 s with the script, see DeliveryPlanStore).
        .onAppear { DeliveryPlanStore.shared.panelAppeared() }
        .onDisappear { DeliveryPlanStore.shared.panelDisappeared() }
    }

    
    /// Opens a cross-check result: load the file in the player at that line with the Subtitles panel open.
    func openSubtitleDifference(video: URL, seconds: Double) {
        let fps = specsState.deliverableAssets.first { $0.fileURL.standardizedFileURL == video.standardizedFileURL }.flatMap { $0.fps > 0 ? $0.fps : nil } ?? 25
        withAnimation(Motion.snap) {
            selectedTab = .player
        }
        playerEngine.loadVideo(url: video, into: .slotA, initialSeekFrame: max(0, Int(ceil(seconds * max(1, fps) - 0.5))))
        playerDrawerTab = .subtitles
        showNotesDrawer = true
    }
    
    // MARK: - Left Panel: Search Filter Bar (like in Tab 1)
    
    private var specsSearchFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: StudioTheme.scaleFont(10)))
                .foregroundColor(textMuted)
            
            ZStack(alignment: .leading) {
                if specsState.specsFilterText.isEmpty {
                    Text("Filter assets...")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $specsState.specsFilterText)
                    .font(.ui(size: 11, weight: .medium))
                    .textFieldStyle(.plain)
                    .foregroundColor(textMain)
                    .padding(.horizontal, 4)
            }
            
            if !specsState.specsFilterText.isEmpty {
                Button(action: { specsState.specsFilterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(textMuted)
                }
                .buttonStyle(.plain)
            }
            
            let present = specsPresentKinds
            if present.nonzeroBitCount > 1 {
                MediaKindFilterChips(mask: $mediaKindFilter, present: present, isLightMode: isLightMode)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .studioBox(background: bgSubtle, border: borderLine)
    }
    
    /// Double-click: the preview in its own window, centred on the screen when it opens (an open one comes forward).
    func openPreviewWindow() {
        let wasOpen = UserDefaults.standard.bool(forKey: InspectPreviewWindow.poppedOutKey)
        openWindow(id: InspectPreviewWindow.id)
        guard !wasOpen else { return }
        DispatchQueue.main.async {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(InspectPreviewWindow.id) == true }?.center()
        }
    }

    // MARK: - Keyboard navigation

    /// Inspect's keys (router scope `.specsOnly`; text fields keep their keys). False = nothing to do.
    func handleInspectNav(_ nav: InspectNav) -> Bool {
        let order = specsState.currentDisplayOrder
        guard !order.isEmpty else { return false }
        let focus = specsState.focusIndex(in: order)
        func go(_ index: Int, extend: Bool = false) -> Bool {
            guard let url = specsState.moveSelection(to: index, extend: extend, order: order) else { return false }
            NotificationCenter.default.post(name: SpecsState.scrollToFile, object: url, userInfo: ["minimal": true])
            return true
        }
        switch nav {
        case .move(let step):
            guard let focus else { return go(step > 0 ? 0 : order.count - 1) }
            return go(focus + step)
        case .extend(let step):
            guard let focus else { return go(step > 0 ? 0 : order.count - 1) }
            return go(focus + step, extend: true)
        case .first: return go(0)
        case .last: return go(order.count - 1)
        case .attention(let step):
            // Next file with a spec mismatch or a plan state that needs a look, wrapping around.
            let start = focus ?? (step > 0 ? -1 : order.count)
            let assets = deliverableAssetsMap   // built once (it's a computed dictionary)
            for offset in 1...order.count {
                let i = ((start + step * offset) % order.count + order.count) % order.count
                if needsAttention(order[i], assets: assets) { return go(i) }
            }
            return false
        case .play:
            guard let url = specsState.selectedDeliverableURL else { return false }
            playDeliverableInPlayer(url: url)
            return true
        case .shuttle(let direction):
            return InspectPreview.shared.shuttle(direction)
        case .step(let frames):
            return InspectPreview.shared.step(frames)
        case .preview:
            // Space plays / pauses the preview; with no preview on screen it opens Media Info instead.
            if InspectPreview.shared.togglePlay() { return true }
            guard specsState.selectedDeliverableURL != nil else { return false }
            togglePropertiesModalForActiveOrSelected()
            return true
        case .selectAll:
            specsState.selectedDeliverableURLs = Set(order)
            if specsState.selectedDeliverableURL == nil { specsState.selectedDeliverableURL = order.first }
            return true
        case .clear:
            guard !specsState.selectedDeliverableURLs.isEmpty else { return false }
            specsState.selectedDeliverableURLs = []
            specsState.selectedDeliverableURL = nil
            return true
        }
    }

    /// A spec mismatch Inspect shows (not dismissed), or a plan state that needs a look.
    private func needsAttention(_ url: URL, assets: [URL: DeliverableAsset]) -> Bool {
        if let state = planFiles[url]?.state, [.wrongSpec, .check, .needsFix].contains(state) { return true }
        guard let asset = assets[url] else { return false }
        return (asset.validation.hasAnyMismatch || specsState.hasSubtitleMismatch(url)) && !specsState.isMismatchDismissed(for: url)
    }

    /// The Delivery Plan's filter chips, as in the plan: % done, All, a chip per state with its file count, Not in Plan.
    var inspectPlanChips: some View {
        // Files the plan hasn't indexed (not measured) count as Not in Plan, as the filter treats them.
        let summary = inspectPlanCounts.summary(assets: specsState.deliverableAssets, version: specsState.assetsVersion,
                                                files: planFiles, filesVersion: planFilesVersion)
        let counts = summary.states
        let total = specsState.deliverableAssets.count
        let done = PlanState.allCases.filter(\.isDone).reduce(0) { $0 + (counts[$1] ?? 0) }
        let live = total - (counts[.dropped] ?? 0) - (counts[nil] ?? 0)
        let palette = StudioPalette(isLightMode)
        let batchItems = summary.batches
        return HStack(alignment: .top, spacing: 4) {
        FlowChips(spacing: 2) {
            if live > 0 { PlanProgressMeter(done: done, live: live, isLightMode: isLightMode) }
            PlanFilterChip(title: "All", count: total, selected: inspectPlanFilter == -1, color: nil, isLightMode: isLightMode) {
                inspectPlanFilter = -1
            }
            ForEach(PlanState.allCases, id: \.self) { state in
                if let n = counts[state], n > 0 {
                    PlanFilterChip(title: state.title, count: n, selected: inspectPlanFilter == state.rawValue,
                                   color: PlanRowView.color(state, palette), isLightMode: isLightMode) {
                        inspectPlanFilter = inspectPlanFilter == state.rawValue ? -1 : state.rawValue
                    }
                }
            }
            if let n = counts[nil], n > 0 {
                PlanFilterChip(title: "Not in Plan", count: n, selected: inspectPlanFilter == -2, color: palette.textSubtle, isLightMode: isLightMode) {
                    inspectPlanFilter = inspectPlanFilter == -2 ? -1 : -2
                }
            }
            PlanBarDivider(isLightMode: isLightMode)
            if batchItems.contains(where: { !$0.name.isEmpty }) || inspectPlanBatch != nil {
                PlanBatchFilter(items: batchItems.filter { !$0.name.isEmpty },
                                unbatched: batchItems.first { $0.name.isEmpty }?.count ?? 0,
                                selection: $inspectPlanBatch, isLightMode: isLightMode)
            }
            // Shown with the plan's: when the sheet has a Frame.io column (read here, not observed: `planFiles` redraws).
            if DeliveryPlanStore.shared.hasFrameIOColumn || inspectPlanUpload != nil {
                let counts = summary.uploads
                PlanUploadFilter(none: counts.none, on: counts.on, selection: $inspectPlanUpload, isLightMode: isLightMode)
            }
            // Kinds a file here can have; files not in the plan have their own chip.
            if DeliveryPlanStore.shared.hasFrameIOColumn || summary.mismatchTotal > 0 || (inspectPlanUpload ?? 0) > 1 {
                PlanMismatchFilter(counts: summary.mismatches, total: summary.mismatchTotal,
                                   kinds: PlanMismatch.allCases.filter { $0.isLocal && $0 != .localExtra },
                                   selection: $inspectPlanUpload, isLightMode: isLightMode,
                                   dismissed: DeliveryPlanStore.shared.planCounts.dismissed)
            }
        }
        // No Spacer: FlowChips takes the width it's offered, and a Spacer would split it in half.
        PlanFilterLinkToggle(isLightMode: isLightMode) { [specsState, inspectPlanFilter, inspectPlanBatch, inspectPlanUpload] in
            DeliveryPlanStore.SharedFilter(state: inspectPlanFilter, search: specsState.specsFilterText, batch: inspectPlanBatch, upload: inspectPlanUpload)
        }
        }
    }

    /// Inspect's files per batch (plan files only; "" = in the plan without a batch), in natural order.

    /// The View menu: Group By, Sort By, Density, then folder / group shortcuts.
    @ViewBuilder
    var inspectViewMenuItems: some View {
        Section("Group By") {
            ForEach(InspectGrouping.allCases, id: \.self) { grouping in
                Toggle(grouping.title, isOn: Binding(get: { inspectGrouping == grouping }, set: { _ in
                    withAnimation(Motion.list) {
                        inspectGroupBy = grouping.rawValue
                        if grouping == .folder { hideAllFolders = false }
                    }
                }))
                .disabled(grouping.needsPlan && planFiles.isEmpty)
            }
        }
        Section("Sort By") { inspectSortMenuItems }
        Section("Density") {
            ForEach([("compact", "Compact"), ("inline", "List"), ("thumbnail", "Thumbnails")], id: \.0) { mode, title in
                Toggle(title, isOn: Binding(get: { specsDisplayMode == mode }, set: { _ in
                    withAnimation(Motion.fade) { specsDisplayMode = mode }
                }))
            }
        }
        if inspectGrouping != .none {
            Divider()
            Button(specsState.deliverablesCollapsedFolderIDs.isEmpty ? "Collapse All Groups" : "Expand All Groups") {
                toggleAllDeliverablesFolders()
            }
            if inspectGrouping == .folder, hideAllFolders || !hiddenFolderIDs.isEmpty {
                Button("Show Hidden Folders") { toggleHideFolders() }
            }
        }
    }

    /// Sort orders (View menu and the table header's right-click): the plan's, then the columns', then the direction.
    @ViewBuilder
    var inspectSortMenuItems: some View {
        if !planFiles.isEmpty {
            ForEach([(1, "Plan Order"), (3, "Problems First"), (2, "Plan Status"), (4, "Code")], id: \.0) { value, title in
                Toggle(title, isOn: Binding(get: { inspectPlanSort == value }, set: { _ in inspectPlanSort = value }))
            }
            Divider()
        }
        ForEach(SpecsSortColumn.allCases, id: \.self) { column in
            Toggle(column.displayName, isOn: Binding(get: { inspectPlanSort == 0 && specsState.specsSortColumn == column },
                                                     set: { _ in toggleSpecsSort(column) }))
        }
        Divider()
        Button(specsState.specsSortAscending ? "Ascending" : "Descending") { specsState.specsSortAscending.toggle() }
            .disabled(inspectPlanSort != 0)
    }

    /// "Columns" in the table's header menu.
    var columnsMenu: some View {
        Menu("Columns") { columnsMenuItems }
    }

    @ViewBuilder
    var columnsMenuItems: some View {
        ForEach(SpecsSortColumn.allCases.filter { $0 != .name }, id: \.self) { column in
            Toggle(column.displayName, isOn: Binding(get: { specsState.isColumnVisible(column) },
                                                     set: { specsState.setColumnVisible(column, $0) }))
        }
        if !specsState.hiddenColumns.isEmpty {
            Divider()
            Button("Show All Columns") { specsState.hiddenColumns = [] }
        }
        Divider()
        Menu("Templates") {
            ForEach(SpecsState.builtInTemplates + specsState.columnTemplates) { template in
                Button(template.name) { specsState.applyColumnTemplate(template) }
            }
            Divider()
            Button("Save Current Columns as Template…") { saveColumnTemplate() }
            if !specsState.columnTemplates.isEmpty {
                Menu("Delete Template") {
                    ForEach(specsState.columnTemplates) { template in
                        Button(template.name) { specsState.deleteColumnTemplate(named: template.name) }
                    }
                }
            }
        }
    }

    /// Asks for a name and saves the visible columns and widths.
    func saveColumnTemplate() {
        let alert = NSAlert()
        alert.messageText = "Save Column Template"
        alert.informativeText = "Saves which columns are shown and their widths. A template with the same name is replaced."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Template name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // A built-in name can't be replaced: save it as "Name 2" instead of silently doing nothing.
        if SpecsState.builtInTemplates.contains(where: { $0.name == name }) { name += " 2" }
        specsState.saveColumnTemplate(named: name)
    }

    // MARK: - Left Panel: 02 SPECS ACTIONS
    
    private var specsActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Specs Actions")
            
            // Actions & Export Controls
            VStack(spacing: 6) {
                // Loudness Check (BS.1770 loudness, true peak, LRA, channel checks) against the chosen target
                VStack(spacing: 4) {
                    Button(action: {
                        if specsState.isAnalyzingAudioLevels {
                            specsState.cancelAudioAnalysis()
                        } else {
                            specsState.analyzeAudioLevels()
                        }
                    }) {
                        HStack(spacing: 6) {
                            if specsState.isAnalyzingAudioLevels {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                                    .frame(width: 10, height: 10)
                                Text("Measuring Loudness (\(specsState.analyzedAudioCount)/\(specsState.totalAudioCount))")
                                    .font(.ui(size: 10, weight: .semibold))
                                    .foregroundColor(accentBlue)
                                Spacer()
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                                    .foregroundColor(textMuted)
                            } else {
                                Image(systemName: "waveform")
                                    .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                                Text(hasPendingAudioAnalysis ? "Check Loudness" : "Recheck Loudness")
                                    .font(.ui(size: 10, weight: .semibold))
                                Spacer()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .padding(.horizontal, 8)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : (hasPendingAudioAnalysis ? textMain : textSubtle))
                        .studioBox(
                            background: hasPendingAudioAnalysis ? accentBlue.opacity(0.12) : bgSubtle,
                            border: hasPendingAudioAnalysis ? accentBlue.opacity(0.5) : borderLine
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Measures loudness (LUFS), true peak, loudness range and channel problems (silent channel, out of phase, dual mono) per ITU-R BS.1770-4, and checks them against the target.")

                    loudnessTargetMenu
                }

                // End Frame Check (on demand: one decoded frame per file)
                Button(action: {
                    if specsState.isCheckingEndFrames { specsState.cancelEndFrameCheck() } else { specsState.checkEndFrames() }
                }) {
                    HStack(spacing: 6) {
                        if specsState.isCheckingEndFrames {
                            ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 10, height: 10)
                            Text("Checking End Frames (\(specsState.checkedEndFrameCount)/\(specsState.totalEndFrameCount))")
                                .font(.ui(size: 10, weight: .semibold))
                                .foregroundColor(accentBlue)
                            Spacer()
                            Image(systemName: "xmark.circle.fill").font(.system(size: StudioTheme.scaleFont(9), weight: .bold)).foregroundColor(textMuted)
                        } else {
                            Image(systemName: "rectangle.lefthalf.inset.filled.arrow.left")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text(hasPendingEndFrameCheck ? "Check End Frames" : "Recheck End Frames")
                                .font(.ui(size: 10, weight: .semibold))
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : (hasPendingEndFrameCheck ? textMain : textSubtle))
                    .studioBox(background: hasPendingEndFrameCheck ? accentBlue.opacity(0.12) : bgSubtle,
                               border: hasPendingEndFrameCheck ? accentBlue.opacity(0.5) : borderLine)
                }
                .buttonStyle(.plain)
                .disabled(specsState.deliverableAssets.isEmpty)
                .explain("Checks whether each video ends on a pure black frame (decodes only the last frame of each file).")
                
                // Subtitle Cross-Check (selection with 2+ files, otherwise the whole list)
                let crossCheckTargets = subtitleCrossCheckTargets
                Button(action: { crossCheckSubtitles(crossCheckTargets) }) {
                    HStack(spacing: 6) {
                        if specsState.isCrossCheckingSubtitles {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                                .frame(width: 10, height: 10)
                        } else {
                            CCBadge(size: 8.5)
                        }
                        Text("Cross-Check Subtitles")
                            .font(.ui(size: 10, weight: .semibold))
                        Spacer()
                        Text(crossCheckTargets.count >= 2 ? "\(crossCheckTargets.count) files" : "Need 2+ SRT")
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(crossCheckTargets.count >= 2 ? accentBlue : textMuted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(borderLine)
                            .cornerRadius(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .foregroundColor(crossCheckTargets.count >= 2 ? textMain : textMuted)
                    .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .disabled(crossCheckTargets.count < 2 || specsState.isCrossCheckingSubtitles)
                .explain("Compares the .srt of the selected files (⌘/⇧-click to select; all files if none selected) and lists any differences.")
                
                // Export Row: SHEETS | SAVE CSV | OPEN HTML (All on one line)
                HStack(spacing: 6) {
                    // Google Sheets
                    Button(action: {
                        if !specsState.deliverableAssets.isEmpty {
                            openDeliverablesInGoogleSheets()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text("Sheets")
                                .font(.ui(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Copies specs as spreadsheet data and opens Google Sheets ready to paste (⌘V).")
                    
                    // Save CSV
                    Button(action: {
                        if !specsState.deliverableAssets.isEmpty {
                            exportDeliverablesManifest()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text("Save CSV")
                                .font(.ui(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Saves the deliverables metadata table to a local CSV file.")
                    
                    // Open HTML
                    Button(action: {
                        if !specsState.deliverableAssets.isEmpty {
                            openManifestHTML()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text("Open HTML")
                                .font(.ui(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(specsState.deliverableAssets.isEmpty ? textMuted : textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .explain("Generates and opens a formatted HTML delivery specs sheet in browser.")
                }
                
                // Reveal in Finder
                if let firstURL = specsState.deliverableAssets.first?.fileURL {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([specsState.selectedDeliverableURL ?? firstURL])
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text("Reveal in Finder")
                                .font(.ui(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 28)
                        .foregroundColor(textMain)
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .explain("Locates and highlights the selected or first asset in macOS Finder.")
                }
            }
            
            // Clear Button
            if !specsState.deliverableAssets.isEmpty {
                Button(action: {
                    specsState.clearDeliverables()
                    specsState.selectedDeliverableURL = nil
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        Text("Clear List")
                            .font(.ui(size: 10, weight: .semibold))
                    }
                    .foregroundColor(textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
                .explain("Removes all video assets from the inspection table.")
            }
        }
    }
    
    var emptyDeliverablesStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("Ready to Inspect Deliverables")
                .font(.system(size: StudioTheme.scaleFont(26), weight: .semibold))
                .foregroundColor(textMain)
            
            Text("Choose a delivery folder or video files on the left to generate a specs audit.\nShows exact timecode lengths, aspect ratios, resolutions, frame rates and sizes.")
                .font(.ui(size: 13))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Spacer()
        }
        .padding(40)
    }
    
    var deliverablesResultsView: some View {
        let displayAssets = filteredDeliverableAssets
        let totalBytes = displayAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = displayAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let mismatchCount = displayAssets.filter { $0.validation.hasAnyMismatch && !specsState.isMismatchDismissed(for: $0.fileURL) }.count
        let target = loudnessTarget
        let measured = displayAssets.compactMap(\.loudness)
        let loudnessFails = measured.filter { target.evaluate($0).verdict == .fail }.count
        
        return VStack(alignment: .leading, spacing: 20) {
            // Header: Clean audit status
            VStack(alignment: .leading, spacing: 2) {
                Text("Audit Complete")
                    .font(.system(size: StudioTheme.scaleFont(22), weight: .semibold))
                    .foregroundColor(textMain)
                if specsState.specsFilterText.isEmpty {
                    Text("\(specsState.deliverableAssets.count) assets analyzed")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                } else {
                    Text("\(displayAssets.count) of \(specsState.deliverableAssets.count) assets (filtered)")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(accentBlue)
                }
            }
            
            // Quick stats on their own row (never squeezed by the table controls), table controls under them.
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    statBox(title: specsState.specsFilterText.isEmpty ? "Total Assets" : "Filtered Assets", val: String(format: "%02d", displayAssets.count))
                    statBox(title: "Name Mismatches", val: String(format: "%02d", mismatchCount), isRed: mismatchCount > 0, isPositive: mismatchCount == 0 && !displayAssets.isEmpty)
                    if !measured.isEmpty {
                        statBox(title: "Loudness Fails (\(target.name))", val: String(format: "%02d", loudnessFails), isRed: loudnessFails > 0, isPositive: loudnessFails == 0)
                    }
                    statBox(title: "Total Runtime", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                    statBox(title: "Total Batch Size", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
                }
                
                // Table controls
                HStack(spacing: 6) {
                    // Button 1: Fit / Reset Name
                    Button(action: { autoFitFileNameColumnWidth() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isFileNameExpanded ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.line.vertical.and.arrow.right")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text(isFileNameExpanded ? "Reset Name" : "Fit Name")
                                .font(.ui(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .foregroundColor(isFileNameExpanded ? textMain : (specsState.deliverableAssets.isEmpty ? textMuted : textSubtle))
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(specsState.deliverableAssets.isEmpty)
                    .fixedSize()
                    .explain(isFileNameExpanded ? "Reset File Name column width back to default (220px)." : "Auto-fit File Name column to fit longest filename without truncation.")
                    
                    // View: Group By, Sort By, Density in one menu (replaces the Folders and List/Thumbs buttons).
                    Menu { inspectViewMenuItems } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.stack")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text(inspectGrouping == .folder || inspectGrouping == .none ? "View" : "By \(inspectGrouping.title)")
                                .font(.ui(size: 10, weight: .semibold))
                        }
                        .foregroundColor(inspectGrouping == .folder ? textMain : accentBlue)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .explain("Group, sort and size Inspect's rows.")

                    // Clean list: hide the plan's chips and badges (filters keep working)
                    if !planFiles.isEmpty {
                        let filtered = inspectPlanFilter != -1 || inspectPlanBatch != nil || inspectPlanUpload != nil
                        Button(action: { withAnimation(Motion.fade) { hidePlanTags.toggle() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: hidePlanTags ? "tag.slash" : "tag")
                                    .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                                Text(hidePlanTags ? "Show Tags" : "Clean List")
                                    .font(.ui(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .foregroundColor(hidePlanTags && filtered ? accentBlue : textMain)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .explain(hidePlanTags
                            ? (filtered ? "Plan tags are hidden; the list is still filtered by plan status. Click to show the tags." : "Show the Delivery Plan chips and badges.")
                            : "Hide the Delivery Plan chips and badges for a clean list (filters keep working).")
                    }

                    // Columns: show / hide
                    Menu { columnsMenuItems } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.split.3x1")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                            Text("Columns")
                                .font(.ui(size: 10, weight: .semibold))
                        }
                        .foregroundColor(specsState.hiddenColumns.isEmpty ? textMain : accentBlue)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .explain("Show or hide Inspect's columns.")

                    // Thumbnail size (thumbnail density only).
                    if specsDisplayMode == "thumbnail" {
                        Button(action: { showSpecsViewOptionsPopover.toggle() }) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                        .explain("Thumbnail size.")
                        .popover(isPresented: $showSpecsViewOptionsPopover, arrowEdge: .bottom) {
                            specsViewOptionsPopoverContent
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            
            if !planFiles.isEmpty && !hidePlanTags { inspectPlanChips.padding(.bottom, 6) }

            // Table
            GeometryReader { tableGeo in
                let geoWidth = floor(tableGeo.size.width)
                let availableWidth = max(specsTableMinWidth, geoWidth)
                let extraWidth = max(0, geoWidth - specsTableMinWidth)
                let pathColWidth = CGFloat(specsState.columnWidth(for: .path)) + extraWidth
                
                ScrollView(.horizontal, showsIndicators: availableWidth > geoWidth) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Table Header
                        HStack(spacing: 8) {
                            Text("#").frame(width: 25, alignment: .center)
                            if specsDisplayMode == "thumbnail" {
                                Text("Preview").frame(width: CGFloat(specsThumbnailWidth), alignment: .center)
                            }
                            
                            // With Path hidden, File Name takes the spare width Path would have (no blank strip).
                            sortableHeaderCell("File Name", column: .name,
                                               customWidth: specsState.isColumnVisible(.path) ? nil : CGFloat(effectiveFileNameColumnWidth) + extraWidth,
                                               alignment: .leading)
                            if specsState.isColumnVisible(.timecode) { sortableHeaderCell("Timecode (TC)", column: .timecode) }
                            if specsState.isColumnVisible(.endFrame) { sortableHeaderCell("End Frame", column: .endFrame) }
                            if specsState.isColumnVisible(.ratio) { sortableHeaderCell("Ratio & Size", column: .ratio) }
                            if specsState.isColumnVisible(.fps) { sortableHeaderCell("FPS", column: .fps) }
                            if specsState.isColumnVisible(.size) { sortableHeaderCell("File Size", column: .size) }
                            if specsState.isColumnVisible(.date) { sortableHeaderCell("Created", column: .date) }
                            if specsState.isColumnVisible(.videoCodec) { sortableHeaderCell("Video", column: .videoCodec) }
                            if specsState.isColumnVisible(.audioCodec) { sortableHeaderCell("Audio Spec", column: .audioCodec) }
                            if specsState.isColumnVisible(.path) {
                                sortableHeaderCell("Path", column: .path, customWidth: pathColWidth, alignment: .leading, isResizable: false)
                            }
                        }
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, specsDisplayMode == "large" ? 10 : (specsDisplayMode == "thumbnail" ? 8 : (specsDisplayMode == "compact" ? 3 : 6)))
                        .frame(width: availableWidth, alignment: .leading)
                        .background(bgCardHeader)
                        .contextMenu {
                            columnsMenu
                            Menu("Sort By") { inspectSortMenuItems }
                            Divider()
                            Button(action: { specsState.specsSortAscending.toggle() }) {
                                Label(specsState.specsSortAscending ? "Ascending" : "Descending", systemImage: specsState.specsSortAscending ? "arrow.up" : "arrow.down")
                            }
                        }
                        
                        Rectangle().fill(borderLine).frame(width: availableWidth, height: 1)
                        
                        // Table Rows
                        ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                let assetMap = deliverableAssetsMap
                                
                                if filteredDeliverableAssets.isEmpty && !specsState.specsFilterText.isEmpty {
                                    VStack(spacing: 10) {
                                        Spacer().frame(height: 40)
                                        Image(systemName: "line.3.horizontal.decrease.circle")
                                            .font(.system(size: StudioTheme.scaleFont(26)))
                                            .foregroundColor(textMuted)
                                        Text("No Assets Matching \"\(specsState.specsFilterText)\"")
                                            .font(.ui(size: 11, weight: .semibold))
                                            .foregroundColor(textMuted)
                                        Button(action: { specsState.specsFilterText = "" }) {
                                            Text("Clear Filter")
                                                .font(.ui(size: 11, weight: .semibold))
                                                .foregroundColor(accentBlue)
                                        }
                                        .buttonStyle(.plain)
                                        Spacer().frame(height: 40)
                                    }
                                    .frame(width: availableWidth)
                                } else {
                                    // One ForEach keyed by path for tree and flat layouts (separate branches with
                                    // shared ids left stale rows in the lazy stack — see AGENTS.md §5.6).
                                    let rows = deliverableRows
                                    let rowCount = rows.count
                                    // Computed once per render and handed to every row (each row used to rebuild the
                                    // sorted list + folder tree for its menus and indent, on every selection change).
                                    let displayOrder = rows.filter { !$0.isDirectory }.map(\.url)
                                    let isTreeLayout = inspectGrouping == .folder ? hasDeliverablesSubfolders && !hideAllFolders : inspectGrouping.needsPlan
                                    let assetIndexMap = Dictionary(uniqueKeysWithValues: displayOrder.enumerated().map { ($0.element, $0.offset) })
                                    let _ = { specsState.currentDisplayOrder = displayOrder }()
                                    // Rows re-render only when something they show changes (like the Player queue):
                                    // a click then updates the 1–2 rows whose selection flipped, not the whole table.
                                    let columnWidths = SpecsSortColumn.allCases.map { specsState.isColumnVisible($0) ? specsState.columnWidth(for: $0) : -1 }
                                    let themeKey = "\(isLightMode)_\(themeManager.currentTheme.id)_\(themeManager.currentTheme.playHex)_\(themeManager.buttonZoom)"
                                    let multiSelectionKey = specsState.selectedDeliverableURLs.count > 1
                                        ? specsState.selectedDeliverableURLs.hashValue &+ tagsVersion &* 31 &+ specsState.subtitleURLs.count : 0
                                    
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, node in
                                        if node.isDirectory {
                                            deliverablesFolderBannerRow(node: node, assetMap: assetMap, rowWidth: availableWidth)
                                        } else if let asset = assetMap[node.url] {
                                            let isSelected = specsState.isSelected(asset.fileURL)
                                            EquatableRow(key: SpecsRowKey(
                                                asset: asset,
                                                idx: assetIndexMap[node.url] ?? idx,
                                                depth: node.depth,
                                                pathWidth: pathColWidth,
                                                rowWidth: availableWidth,
                                                isTreeLayout: isTreeLayout,
                                                isSelected: isSelected,
                                                isDismissed: specsState.isMismatchDismissed(for: asset.fileURL),
                                                hasSubtitleMismatch: specsState.hasSubtitleMismatch(asset.fileURL),
                                                srtURL: specsState.subtitleURL(for: asset.fileURL),
                                                hasManualSrt: specsState.manuallyAttachedSubtitleVideos.contains(asset.fileURL),
                                                tag: fileTagsMap[asset.fileURL],
                                                columnWidths: columnWidths,
                                                displayMode: specsDisplayMode,
                                                thumbnailWidth: specsThumbnailWidth,
                                                themeKey: themeKey,
                                                menuContext: isSelected ? multiSelectionKey : 0,
                                                plan: hidePlanTags ? nil : planFiles[asset.fileURL]
                                            )) {
                                                deliverablesAssetRow(idx: assetIndexMap[node.url] ?? idx, asset: asset, depth: node.depth, pathWidth: pathColWidth, rowWidth: availableWidth, displayOrder: displayOrder, isTreeLayout: isTreeLayout)
                                            }
                                            .equatable()
                                        }
                                        
                                        if idx < rowCount - 1 {
                                            Rectangle().fill(borderLine.opacity(0.4)).frame(width: availableWidth, height: 1)
                                        }
                                    }
                                }
                            }
                            // Rebuild rows when the display mode / thumbnail size changes.
                            .id("\(specsDisplayMode)_\(Int(specsThumbnailWidth))")
                        }
                        .onReceive(NotificationCenter.default.publisher(for: SpecsState.scrollToFile)) { notification in
                            guard let url = notification.object as? URL else { return }
                            guard let id = deliverableRows.first(where: { $0.url == url && !$0.isDirectory })?.id else {
                                // In a collapsed group or folder: open the ones holding it, then scroll once they're drawn.
                                let tree = inspectGrouping.needsPlan ? planGroupTree : deliverablesTree
                                func holders(_ nodes: [FileSystemTreeNode]) -> [String] {
                                    nodes.filter { $0.isDirectory && $0.videoURLs.contains(url) }.flatMap { [$0.id] + holders($0.children) }
                                }
                                let opened = Set(holders(tree)).intersection(specsState.deliverablesCollapsedFolderIDs)
                                guard !opened.isEmpty else { return }
                                specsState.deliverablesCollapsedFolderIDs.subtract(opened)
                                DispatchQueue.main.async { NotificationCenter.default.post(notification) }
                                return
                            }
                            // Keyboard steps scroll only as far as needed (no animation: key repeat must keep up);
                            // a plan click centres the file.
                            if notification.userInfo?["minimal"] as? Bool == true {
                                proxy.scrollTo(id)
                            } else {
                                withAnimation(Motion.list) { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                        }
                    }
                    .frame(width: availableWidth, alignment: .leading)
                }
            }
            .studioBox(background: bgPanel, border: borderLine)
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius))
        }
        .padding(28)
    }
    
    // MARK: - Column Resizing & Width Helpers
    
    /// Rows as shown: the folder tree (when there are subfolders), plan groups (batch / status / channel), or the flat
    /// list as depth-0 nodes.
    private var deliverableRows: [FileSystemTreeNode] {
        switch inspectGrouping {
        case .folder where hasDeliverablesSubfolders: return flattenedDeliverableNodes
        case .batch, .status, .channel:
            return FileSystemTreeBuilder.flatten(nodes: planGroupTree, collapsedIDs: specsState.deliverablesCollapsedFolderIDs)
        default: break
        }
        return filteredDeliverableAssets.map {
            FileSystemTreeNode(id: $0.fileURL.path, name: $0.fileName, url: $0.fileURL, isDirectory: false, relativePath: $0.fileName, depth: 0)
        }
    }
    
    /// Visible files in display order (for ⇧-click ranges and multi-file actions).
    var displayedDeliverableURLs: [URL] {
        deliverableRows.filter { !$0.isDirectory }.map(\.url)
    }
    
    var effectiveFileNameColumnWidth: Double {
        specsState.effectiveFileNameColumnWidth
    }
    
    var isFileNameExpanded: Bool {
        specsState.isFileNameExpanded
    }
    
    func autoFitFileNameColumnWidth() {
        withAnimation(Motion.fade) {
            specsState.autoFitFileNameColumnWidth(filteredAssets: filteredDeliverableAssets)
        }
    }
    
    var specsThumbnailWidth: Double {
        specsDisplayMode == "thumbnail" ? max(36.0, min(220.0, specsThumbnailSize)) : 0.0
    }
    
    var specsTableMinWidth: CGFloat {
        let previewWidth: CGFloat = CGFloat(specsThumbnailWidth)
        // Visible columns only (each adds its width and the 8 pt row spacing).
        let others = SpecsSortColumn.allCases.filter { $0 != .name && specsState.isColumnVisible($0) }
        let otherColumnsWidth: CGFloat = 25 + previewWidth +
            others.reduce(0) { $0 + CGFloat(specsState.columnWidth(for: $1)) } +
            CGFloat(8 * (others.count + 3)) + 28
        return CGFloat(effectiveFileNameColumnWidth) + otherColumnsWidth
    }
    
    // MARK: - Finder-Style Column Sorting & Resizing Helpers
    
    func toggleSpecsSort(_ column: SpecsSortColumn) {
        inspectPlanSort = 0
        withAnimation(Motion.fade) {
            specsState.toggleSpecsSort(column)
        }
    }
    
    private func sortableHeaderCell(
        _ title: String,
        column: SpecsSortColumn,
        customWidth: CGFloat? = nil,
        alignment: Alignment = .center,
        isResizable: Bool = true
    ) -> some View {
        let isCurrent = specsState.specsSortColumn == column && inspectPlanSort == 0   // a plan sort replaces the column sort
        let colWidth = customWidth ?? CGFloat(specsState.columnWidth(for: column))
        let isDraggingThis = specsState.isDragging(column: column)
        
        return HStack(spacing: 0) {
            Button(action: { toggleSpecsSort(column) }) {
                HStack(spacing: 3) {
                    Text(title)
                        .lineLimit(1)
                        .foregroundColor(isCurrent ? textMain : textMuted)
                    
                    if isCurrent {
                        Image(systemName: specsState.specsSortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: StudioTheme.scaleFont(7), weight: .black))
                            .foregroundColor(accentBlue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isResizable {
                // Drag Resize Handle Divider (14px hit target zone)
                ZStack {
                    ResizeCursorArea()
                        .frame(width: 14, height: 24)
                    Rectangle()
                        .fill(isDraggingThis ? accentBlue : (hoveredResizeColumn == column ? PanelResizeHandle.hoverLine(isLightMode) : borderLine.opacity(0.85)))
                        .frame(width: isDraggingThis ? 2 : 1, height: hoveredResizeColumn == column || isDraggingThis ? 16 : 12)
                        .allowsHitTesting(false)
                }
                .frame(width: 14)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if column == .name {
                        autoFitFileNameColumnWidth()
                    } else {
                        specsState.resetColumnWidth(for: column)
                    }
                }
                .onHover { isHovered in
                    if isHovered { hoveredResizeColumn = column } else if hoveredResizeColumn == column { hoveredResizeColumn = nil }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            specsState.onColumnDragChanged(column: column, translationWidth: Double(value.translation.width))
                        }
                        .onEnded { value in
                            specsState.onColumnDragEnded(column: column, translationWidth: Double(value.translation.width))
                        }
                )
            }
        }
        .frame(
            minWidth: column == .path ? colWidth : nil,
            idealWidth: colWidth,
            maxWidth: column == .path ? (customWidth != nil ? colWidth : .infinity) : colWidth,
            alignment: alignment
        )
        .explain("Sort by \(title.lowercased()) (\(isCurrent ? (specsState.specsSortAscending ? "ascending" : "descending") : "click to sort"))." + (isResizable ? " Drag divider to resize." : ""))
    }
    
    func sortDeliverableAssets(_ assets: [DeliverableAsset]) -> [DeliverableAsset] {
        specsState.sortDeliverableAssets(assets)
    }
    
    // MARK: - Deliverables Filtering & Hierarchy Helpers
    
    var specsPresentKinds: Int { MediaKindFilter.presentMask(of: specsState.deliverableAssets.map(\.fileURL)) }
    var specsKindMask: Int { MediaKindFilter.effectiveMask(mediaKindFilter, present: specsPresentKinds) }
    
    var filteredDeliverableAssets: [DeliverableAsset] {
        let files = planFiles, filter = inspectPlanFilter, batch = inspectPlanBatch, upload = inspectPlanUpload
        return specsState.displayedAssets(
            filter: specsState.specsFilterText.trimmingCharacters(in: .whitespacesAndNewlines), mask: specsKindMask,
            planKey: files.isEmpty ? "" : "\(filter)|\(batch ?? "*")|\(upload ?? -1)|\(planFilesVersion)|\(inspectPlanSort)",
            planAllows: (filter == -1 && batch == nil && upload == nil) || files.isEmpty ? nil : { url in
                let info = files[url]
                if let batch, info?.rowID == nil || info?.batch != batch { return false }
                if let upload, !(info?.passes(upload) ?? (upload == PlanMismatch.localExtra.rawValue)) { return false }
                guard filter != -1 else { return true }
                guard let info else { return filter == -2 }
                return filter == -2 ? info.state == nil : info.state?.rawValue == filter
            },
            planText: files.isEmpty ? nil : { files[$0]?.text },
            planSort: files.isEmpty || inspectPlanSort == 0 ? nil : { [sort = inspectPlanSort] url in
                guard let info = files[url], let state = info.state else { return Int.max }   // not in the plan: last
                switch sort {
                case 1: return info.line
                case 3: return (InspectGrouping.statusOrder.firstIndex(of: state) ?? 99) * 100_000 + info.line   // problems first
                case 4: return (Int(info.code.filter(\.isNumber)) ?? Int.max / 200_000) * 100_000 + info.line    // code number
                default: return state.rawValue * 100_000 + info.line
                }
            })
    }
    
    var deliverablesTree: [FileSystemTreeNode] {
        FileSystemTreeBuilder.buildTree(
            rootURL: folderURL,
            files: filteredDeliverableAssets.map { $0.fileURL },
            preserveFileOrder: true
        )
    }
    
    var hasDeliverablesSubfolders: Bool {
        FileSystemTreeBuilder.hasSubfolders(in: deliverablesTree)
    }
    
    private var loudnessTargetMenu: some View {
        Menu {
            Picker("Loudness Target", selection: $loudnessTargetID) {
                ForEach(LoudnessTarget.presets) { preset in
                    Text("\(preset.name)  (\(preset.spec))").tag(preset.id)
                }
                Text("Custom  (\(LoudnessTarget.custom(integrated: loudnessCustomLUFS, tolerance: loudnessCustomTolerance, maxTruePeak: loudnessCustomTruePeak).spec))").tag("custom")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Custom Target…") {
                UserDefaults.standard.set("Loudness", forKey: UserSettingsModalView.paneKey)
                loudnessTargetID = "custom"
                showUserSettingsModal = true
            }
        } label: {
            HStack(spacing: 4) {
                Text("Target")
                    .foregroundColor(textMuted)
                Text("\(loudnessTarget.name) · \(loudnessTarget.spec)")
                    .foregroundColor(textSubtle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: StudioTheme.scaleFont(7), weight: .semibold))
                    .foregroundColor(textMuted)
            }
            .font(.ui(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Loudness target used to pass or fail each file")
    }

    func loudnessColor(_ verdict: LoudnessTarget.Verdict) -> Color {
        switch verdict {
        case .pass: return accentPositive
        case .warn: return .orange
        case .fail: return alertRed
        }
    }

    private func loudnessHelp(for asset: DeliverableAsset) -> String {
        guard let loudness = asset.loudness else { return asset.audioConfig }
        let result = loudnessTarget.evaluate(loudness)
        var lines = [asset.audioConfig, "", "\(result.verdict.rawValue) · \(loudnessTarget.name) (\(loudnessTarget.spec))"]
        lines += result.issues.filter { !loudness.channelNotes.contains($0) }
        lines += ["", loudness.detail]
        return lines.joined(separator: "\n")
    }

    var hasPendingAudioAnalysis: Bool {
        specsState.deliverableAssets.contains { $0.hasAudio && $0.loudness == nil && !$0.isAudioMute }
    }
    
    var flattenedDeliverableNodes: [FileSystemTreeNode] {
        FileSystemTreeBuilder.flatten(
            nodes: deliverablesTree,
            collapsedIDs: specsState.deliverablesCollapsedFolderIDs,
            hiddenIDs: hiddenFolderIDs,
            hideAllFolders: hideAllFolders
        )
    }
    
    var deliverableAssetsMap: [URL: DeliverableAsset] {
        Dictionary(uniqueKeysWithValues: filteredDeliverableAssets.map { ($0.fileURL, $0) })
    }
    
    private func toggleAllDeliverablesFolders() {
        if specsState.deliverablesCollapsedFolderIDs.isEmpty {
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
            let tree = inspectGrouping.needsPlan ? planGroupTree : deliverablesTree
            specsState.deliverablesCollapsedFolderIDs = Set(tree.flatMap { collectFolderIDs($0) })
        } else {
            specsState.deliverablesCollapsedFolderIDs.removeAll()
        }
    }
    
    var isDeliverablesFolderRowCollapsed: (FileSystemTreeNode) -> Bool {
        { node in
            specsState.deliverablesCollapsedFolderIDs.contains(node.id)
        }
    }
    
    private func deliverablesFolderBannerRow(node: FileSystemTreeNode, assetMap: [URL: DeliverableAsset], rowWidth: CGFloat = 0) -> some View {
        let isCollapsed = isDeliverablesFolderRowCollapsed(node)
        let folderAssets = node.videoURLs.compactMap { assetMap[$0] }
        let folderMismatches = folderAssets.filter { $0.validation.hasAnyMismatch && !specsState.isMismatchDismissed(for: $0.fileURL) }.count
        let totalBytes = folderAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = folderAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let formattedSize = DeliverablesInspector.formatFileSize(bytes: totalBytes)
        let formattedDur = TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0)
        // A plan group (Group By batch / status / channel) rather than a folder: its own icon, no folder actions.
        let isGroup = node.id.hasPrefix("group:")
        
        return HStack(spacing: 8) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                .foregroundColor(textMuted)
                .frame(width: 25, alignment: .center)
            
            HStack(spacing: 6) {
                Image(systemName: isGroup ? "square.stack" : "folder")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                    .foregroundColor(textSubtle)
                    .frame(width: 14, height: 14)
                
                Text(node.relativePath.isEmpty ? node.name : "\(node.relativePath)/")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(textMain)
                    .lineLimit(1)
                
                Text("(\(node.videoCount) \(node.videoCount == 1 ? "asset" : "assets"))")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(textMuted)
            }
            .padding(.leading, CGFloat(node.depth * 14))
            
            Spacer()
            
            HStack(spacing: 12) {
                Text(formattedDur)
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(textSubtle)
                
                Text(formattedSize)
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(textSubtle)
                
                if folderMismatches > 0 {
                    Text("\(folderMismatches) mismatch\(folderMismatches == 1 ? "" : "es")")
                        .font(.ui(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(alertRed))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
        .background(bgCardHeader)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed {
                specsState.deliverablesCollapsedFolderIDs.remove(node.id)
            } else {
                specsState.deliverablesCollapsedFolderIDs.insert(node.id)
            }
        }
        .explain(isGroup ? node.name : node.url.path)
        .contextMenu {
            if isGroup {
                Button(isCollapsed ? "Expand Group" : "Collapse Group") {
                    if isCollapsed { specsState.deliverablesCollapsedFolderIDs.remove(node.id) }
                    else { specsState.deliverablesCollapsedFolderIDs.insert(node.id) }
                }
            } else {
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
    }
    
    /// The Audio Spec cell (its own function: inline, the row was too much for the type checker).
    @ViewBuilder
    private func audioCell(_ asset: DeliverableAsset, isDismissed: Bool) -> some View {
        if !asset.hasAudio {
            Text("None")
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(textMuted)
                .frame(width: CGFloat(specsState.columnWidth(for: .audioCodec)), alignment: .center)
        } else {
            VStack(alignment: .center, spacing: 3) {
                HStack(spacing: 4) {
                    Text(asset.audioCodec)
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMain)
                    if asset.audioBitrate != "--" {
                        Text(asset.audioBitrate)
                            .font(.ui(size: 10, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .foregroundColor(textSubtle)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                }

                if asset.validation.isAudioMute {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                        Text(asset.validation.audioMuteDetail ?? "Mute")
                            .font(.ui(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .foregroundColor(alertRed)
                    .background(alertRed.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(alertRed.opacity(0.35), lineWidth: 0.8)
                    )
                    .cornerRadius(3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help("Audio Track is Mute: \(asset.audioLevelString) (Codec: \(asset.audioCodec))")
                } else if let loudness = asset.loudness {
                    let result = loudnessTarget.evaluate(loudness)
                    HStack(spacing: 3) {
                        if result.verdict != .pass {
                            Image(systemName: result.verdict == .fail ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                        }
                        Text(loudness.summary)
                            .font(.ui(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(loudnessColor(result.verdict))
                } else {
                    HStack(spacing: 4) {
                        if !asset.audioFormatDetail.isEmpty {
                            Text(asset.audioFormatDetail)
                                .font(.ui(size: 10, weight: .medium))
                                .foregroundColor(textMuted)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(width: CGFloat(specsState.columnWidth(for: .audioCodec)), alignment: .center)
            .help(loudnessHelp(for: asset))
        }
    }

    private func deliverablesAssetRow(
        idx: Int,
        asset: DeliverableAsset,
        depth: Int = 0,
        pathWidth: CGFloat = 0,
        rowWidth: CGFloat = 0,
        displayOrder: [URL],
        isTreeLayout: Bool
    ) -> some View {
        let isDismissed = specsState.isMismatchDismissed(for: asset.fileURL)
        let hasSubtitleMismatch = specsState.hasSubtitleMismatch(asset.fileURL)
        let hasMismatch = (asset.validation.hasAnyMismatch || hasSubtitleMismatch) && !isDismissed
        let isSelected = specsState.isSelected(asset.fileURL)
        let srtURL = specsState.subtitleURL(for: asset.fileURL)
        
        return HStack(spacing: 8) {
            Text(String(format: "%02d", idx + 1))
                .frame(width: 25, alignment: .center)
                .foregroundColor(isSelected ? accentBlue : textMuted)
                .fontWeight(isSelected ? .bold : .regular)
            
            if specsDisplayMode == "thumbnail" {
                let thumbW = CGFloat(specsThumbnailWidth)
                let thumbH = round(thumbW * 9.0 / 16.0)
                AssetThumbnailView(fileURL: asset.fileURL, width: thumbW, height: thumbH, cornerRadius: 2.5,
                                   skimDuration: QCUtilities.mediaKind(of: asset.fileURL) == .video ? asset.durationSeconds : 0,
                                   skimFPS: asset.fps)
                    .frame(width: thumbW, alignment: .center)
            }
            
            HStack(spacing: 5) {
                if isTreeLayout && depth > 0 {
                    Spacer().frame(width: CGFloat((depth - 1) * 12 + 4))
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        .foregroundColor(textMuted.opacity(0.55))
                }
                
                if let tag = fileTagsMap[asset.fileURL] {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 6, height: 6)
                }
                
                if specsDisplayMode != "thumbnail", let kind = QCUtilities.mediaKind(of: asset.fileURL) {
                    Image(systemName: asset.container == "SEQ" ? "photo.stack" : kind.symbolName)
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                        .foregroundColor(textMuted)
                        .frame(width: 12)
                }
                
                if let srtURL = srtURL {
                    CCBadge(color: hasSubtitleMismatch && !isDismissed ? alertRed : textMuted, size: 9)
                        .help(hasSubtitleMismatch ? "Subtitles differ from the reference (\(srtURL.lastPathComponent))" : "Subtitles: \(srtURL.lastPathComponent)")
                }
                
                Text(asset.fileName)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(isSelected ? textMain : (hasMismatch ? alertRed : textMain))
                    .help(asset.fileName)

                if !hidePlanTags, let plan = planFiles[asset.fileURL] {
                    PlanPill(info: plan, isLightMode: isLightMode)
                }
                
                Button(action: {
                    specsState.selectedDeliverableURL = asset.fileURL
                    openProperties(for: asset.fileURL)
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                        .foregroundColor(isSelected ? accentBlue : textMuted.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Media Info (⌘I)")
            }
            .frame(width: specsState.isColumnVisible(.path) ? CGFloat(effectiveFileNameColumnWidth)
                   : CGFloat(effectiveFileNameColumnWidth) + max(0, pathWidth - CGFloat(specsState.columnWidth(for: .path))),
                   alignment: .leading)
            
            if specsState.isColumnVisible(.timecode) {
                // Timecode Cell with Warning
                VStack(alignment: .center, spacing: 3) {
                    Text(asset.timecode)
                        .foregroundColor((asset.validation.isDurationMismatch && !isDismissed) ? alertRed : textSubtle)
                        .fontWeight((asset.validation.isDurationMismatch && !isDismissed) ? .bold : .regular)
                
                    if let detail = asset.validation.durationMismatchDetail {
                        HStack(spacing: 3) {
                            Image(systemName: isDismissed ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                            Text(isDismissed ? "\(detail) (dismissed)" : detail)
                                .font(.ui(size: 10, weight: isDismissed ? .medium : .semibold))
                        
                            Button(action: {
                                specsState.toggleDismissMismatch(for: asset.fileURL)
                            }) {
                                Image(systemName: isDismissed ? "arrow.uturn.backward" : "xmark")
                                    .font(.system(size: StudioTheme.scaleFont(7), weight: .heavy))
                                    .foregroundColor(isDismissed ? textMuted : alertRed)
                                    .padding(1)
                            }
                            .buttonStyle(.plain)
                            .help(isDismissed ? "Restore Mismatch Flag" : "Dismiss Mismatch Flag")
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .foregroundColor(isDismissed ? textMuted : alertRed)
                        .background(isDismissed ? bgSubtle : alertRed.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isDismissed ? borderLine : alertRed.opacity(0.35), lineWidth: 0.8)
                        )
                        .cornerRadius(3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help("Duration Mismatch: \(detail) (Actual Timecode: \(asset.timecode))\(isDismissed ? " [Dismissed]" : "")")
                    }
                }
                .frame(width: CGFloat(specsState.columnWidth(for: .timecode)), alignment: .center)
            }
            
            if specsState.isColumnVisible(.endFrame) {
                endFrameCell(asset.endFrame)
                    .frame(width: CGFloat(specsState.columnWidth(for: .endFrame)), alignment: .center)
            }
            
            if specsState.isColumnVisible(.ratio) {
                // Ratio Cell with Warning
                VStack(alignment: .center, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(asset.aspectRatioString)
                            .font(.ui(size: 10, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .foregroundColor((asset.validation.isRatioMismatch && !isDismissed) ? .white : textMain)
                            .studioBox(
                                background: (asset.validation.isRatioMismatch && !isDismissed) ? alertRed : bgSubtle,
                                border: (asset.validation.isRatioMismatch && !isDismissed) ? alertRed : borderLine
                            )
                    
                        Text(asset.resolutionString)
                            .foregroundColor(textSubtle)
                    }
                
                    if let detail = asset.validation.ratioMismatchDetail {
                        HStack(spacing: 3) {
                            Image(systemName: isDismissed ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                .font(.system(size: StudioTheme.scaleFont(7), weight: .bold))
                            Text(isDismissed ? "\(detail) (dismissed)" : detail)
                                .font(.ui(size: 10, weight: isDismissed ? .medium : .semibold))
                        
                            Button(action: {
                                specsState.toggleDismissMismatch(for: asset.fileURL)
                            }) {
                                Image(systemName: isDismissed ? "arrow.uturn.backward" : "xmark")
                                    .font(.system(size: StudioTheme.scaleFont(7), weight: .heavy))
                                    .foregroundColor(isDismissed ? textMuted : alertRed)
                                    .padding(1)
                            }
                            .buttonStyle(.plain)
                            .help(isDismissed ? "Restore Mismatch Flag" : "Dismiss Mismatch Flag")
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .foregroundColor(isDismissed ? textMuted : alertRed)
                        .background(isDismissed ? bgSubtle : alertRed.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isDismissed ? borderLine : alertRed.opacity(0.35), lineWidth: 0.8)
                        )
                        .cornerRadius(3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help("Aspect Ratio Mismatch: \(detail) (Actual Resolution: \(asset.resolutionString))\(isDismissed ? " [Dismissed]" : "")")
                    }
                }
                .frame(width: CGFloat(specsState.columnWidth(for: .ratio)), alignment: .center)
            }
            
            if specsState.isColumnVisible(.fps) {
                Text(asset.fps > 0 ? String(format: "%.2f", asset.fps) : "--")
                    .frame(width: CGFloat(specsState.columnWidth(for: .fps)), alignment: .center)
                    .foregroundColor(textSubtle)
            }
            
            if specsState.isColumnVisible(.size) {
                Text(asset.formattedFileSize)
                    .frame(width: CGFloat(specsState.columnWidth(for: .size)), alignment: .center)
                    .fontWeight(.semibold)
            }
            
            if specsState.isColumnVisible(.date) {
                // Creation Date Column
                Text(asset.formattedCreationDate)
                    .font(.ui(size: 10))
                    .foregroundColor(textSubtle)
                    .frame(width: CGFloat(specsState.columnWidth(for: .date)), alignment: .center)
            }
            
            if specsState.isColumnVisible(.videoCodec) {
                Text(asset.videoCodec)
                    .frame(width: CGFloat(specsState.columnWidth(for: .videoCodec)), alignment: .center)
                    .foregroundColor(textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(asset.videoCodec)
            }
            
            if specsState.isColumnVisible(.audioCodec) {
                audioCell(asset, isDismissed: isDismissed)
            }
            
            if specsState.isColumnVisible(.path) {
                let effectivePathWidth = pathWidth > 0 ? pathWidth : CGFloat(specsState.columnWidth(for: .path))
                // Start of the path only (less clutter); click reveals the file in Finder, full path on hover.
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL]) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: StudioTheme.scaleFont(9)))
                        Text(asset.fileURL.deletingLastPathComponent().path)
                            .font(.ui(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundColor(textSubtle)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .frame(width: effectivePathWidth, alignment: .leading)
                .help("Reveal in Finder: \(asset.fileURL.path)")
            }
        }
        .font(.ui(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, specsDisplayMode == "large" ? 10 : (specsDisplayMode == "thumbnail" ? 7 : (specsDisplayMode == "compact" ? 1 : 4)))
        .frame(width: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
        .background(
            isSelected ? accentBlue.opacity(0.14) : (hasMismatch ? alertRed.opacity(0.12) : (idx % 2 == 0 ? bgPanel : bgCardSubtle))
        )
        .overlay(
            isSelected ? Rectangle().fill(accentBlue).frame(width: 3) : (hasMismatch ? Rectangle().fill(alertRed).frame(width: 3) : nil),
            alignment: .leading
        )
        .contentShape(Rectangle())
        // Finder-style: click selects, ⌘-click adds/removes, ⇧-click extends a range. Simultaneous with the double-click
        // (play) so a single click selects immediately instead of waiting out the double-click interval.
        .simultaneousGesture(TapGesture().onEnded {
            specsState.handleClick(on: asset.fileURL, modifiers: NSEvent.modifierFlags, displayOrder: specsState.currentDisplayOrder)
        })
        .simultaneousGesture(
            // Double-click plays the file in Inspect's preview (opening the panel if needed); the Player is in the
            // right-click menu (Open in Player) and on Return.
            TapGesture(count: 2).onEnded {
                specsState.selectedDeliverableURL = asset.fileURL
                openPreviewWindow()
                InspectPreview.shared.playNow(asset.fileURL)
            }
        )
        .explain(asset.fileURL.path)
        .contextMenu {
            Button(action: {
                specsState.selectedDeliverableURL = asset.fileURL
                playDeliverableInPlayer(url: asset.fileURL)
            }) {
                Label("Open in Player", systemImage: "play.fill")
            }
            if planFiles[asset.fileURL]?.rowID != nil {
                // The selection's rows are looked up only when an item is chosen, not while the menu is built (after ⌘A
                // every selected row rebuilds its menu).
                let isMulti = specsState.isSelected(asset.fileURL) && specsState.selectedDeliverableURLs.count > 1
                let url = asset.fileURL
                let targetFiles: () -> [URL] = { [specsState] in
                    specsState.isSelected(url) ? Array(specsState.selectedDeliverableURLs) : [url]
                }
                Menu(isMulti ? "Set Plan Status (Selection)" : "Set Plan Status") {
                    ForEach(PlanQCStatus.allCases, id: \.self) { status in
                        Button("\(status.title)  \(status.shortcut)") {
                            DeliveryPlanStore.shared.setStatus(status, rowIDs: DeliveryPlanStore.shared.rowIDs(forFiles: targetFiles()))
                        }
                    }
                    Divider()
                    Button("Clear Status") { DeliveryPlanStore.shared.setStatus(nil, rowIDs: DeliveryPlanStore.shared.rowIDs(forFiles: targetFiles())) }
                }
                PlanBatchMenu(title: isMulti ? "Set Plan Batch (Selection)" : "Set Plan Batch",
                              rowIDs: { DeliveryPlanStore.shared.rowIDs(forFiles: targetFiles()) })
                if planFiles[asset.fileURL]?.mismatches.isEmpty == false {
                    Button(isMulti ? "Dismiss Plan Mismatches (Selection)" : "Dismiss Plan Mismatch") {
                        DeliveryPlanStore.shared.dismissMismatches(rowIDs: DeliveryPlanStore.shared.rowIDs(forFiles: targetFiles()))
                    }
                }
                if let link = planFiles[asset.fileURL]?.frameio, let web = URL(string: link), !link.isEmpty {
                    Button("Open in Frame.io") { NSWorkspace.shared.open(web) }
                } else {
                    Button("Link Frame.io File…") {
                        PlanFrameIOLinker.ask(store: DeliveryPlanStore.shared, rowIDs: DeliveryPlanStore.shared.rowIDs(forFiles: targetFiles()))
                    }
                }
                Button(isMulti ? "Run Plan Checks on Selection" : "Run Plan Checks on This File") {
                    let store = DeliveryPlanStore.shared, queue = PlanCheckQueue.shared
                    queue.loadIfNeeded()
                    let files = targetFiles()
                    let wanted = Set(files)
                    var seen = Set<URL>()
                    let ids = Set(store.rowIDs(forFiles: files))
                    let stamps = store.rows.filter { ids.contains($0.id) }.flatMap { store.fileStamps($0) }
                        .filter { wanted.contains($0.url) && seen.insert($0.url).inserted }
                    queue.enqueue(stamps, kinds: queue.kinds)
                }
            }
            Divider()
            Button(action: {
                specsState.selectedDeliverableURL = asset.fileURL
                openProperties(for: asset.fileURL)
            }) {
                Label("Media Info (⌘I)", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: .command)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(asset.fileURL.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL])
            }
            Divider()
            let subtitleTargets = specsState.actionTargets(for: asset.fileURL, displayOrder: displayOrder)
            if subtitleTargets.count > 1 {
                Button(action: { crossCheckSubtitles(subtitleTargets) }) {
                    Label("Cross-Check Subtitles (\(subtitleTargets.count) files)", systemImage: "text.badge.checkmark")
                }
                .disabled(subtitleTargets.filter { specsState.subtitleURL(for: $0) != nil }.count < 2)
            }
            Button(action: { attachSubtitles(to: asset.fileURL) }) {
                Label(srtURL == nil ? "Attach Subtitles (.srt)…" : "Change Subtitles (.srt)…", systemImage: "captions.bubble")
            }
            if specsState.manuallyAttachedSubtitleVideos.contains(asset.fileURL) {
                Button("Detach Subtitles") { specsState.attachSubtitles(nil, to: asset.fileURL) }
            }
            if let srtURL = srtURL {
                Button("Reveal Subtitles in Finder") { NSWorkspace.shared.activateFileViewerSelecting([srtURL]) }
            }
            if asset.validation.hasAnyMismatch || hasSubtitleMismatch {
                Divider()
                Button(action: {
                    specsState.toggleDismissMismatch(for: asset.fileURL)
                }) {
                    if isDismissed {
                        Label("Restore Mismatch Flag", systemImage: "arrow.uturn.backward.circle")
                    } else {
                        Label("Dismiss Mismatch Flag", systemImage: "xmark.circle")
                    }
                }
            }
            Divider()
            let tagTargets = specsState.actionTargets(for: asset.fileURL, displayOrder: displayOrder)
            Menu(tagTargets.count > 1 ? "Tags (\(tagTargets.count) files)" : "Tags") {
                ForEach(FinderTagColor.allCases) { tag in
                    let allTagged = tagTargets.allSatisfy { fileTagsMap[$0] == tag }
                    Button(action: {
                        // Like Finder: if every file already has the tag, remove it; otherwise apply it to all.
                        for url in tagTargets { setFinderTag(allTagged ? nil : tag, for: url) }
                    }) {
                        HStack {
                            Text(tag.rawValue)
                            if allTagged {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button(action: {
                    for url in tagTargets { setFinderTag(nil, for: url) }
                }) {
                    Text(tagTargets.count > 1 ? "Remove Tags" : "Remove Tag")
                }
            }
        }
    }
    
    // MARK: - Subtitle Attach & Cross-Check
    
    func attachSubtitles(to video: URL) {
        let panel = NSOpenPanel()
        panel.title = "Attach Subtitles to \(video.lastPathComponent)"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.directoryURL = video.deletingLastPathComponent()
        guard panel.runModal() == .OK, let srt = panel.url else { return }
        specsState.attachSubtitles(srt, to: video)
        showToast("Attached \(srt.lastPathComponent) to \(video.lastPathComponent)")
    }
    
    /// Cross-checks the given videos' subtitles; the first one in list order is the reference.
    func crossCheckSubtitles(_ videos: [URL]) {
        let withSubs = videos.filter { specsState.subtitleURL(for: $0) != nil }
        guard withSubs.count >= 2 else {
            showToast("Need at least 2 files with subtitles to cross-check")
            return
        }
        let fps = Dictionary(uniqueKeysWithValues: specsState.deliverableAssets.map { ($0.fileURL, $0.fps) })
        specsState.runSubtitleCrossCheck(videos: withSubs, fpsByVideo: fps)
    }
    
    /// Files the sidebar action checks: the selection if it has 2+ files, otherwise the whole visible list.
    var subtitleCrossCheckTargets: [URL] {
        let shown = displayedDeliverableURLs
        let selected = shown.filter { specsState.isSelected($0) }
        return (selected.count >= 2 ? selected : shown).filter { specsState.subtitleURL(for: $0) != nil }
    }
    
    // MARK: - Specs View Options Popover (Thumbnail View / List View / Size Slider)
    private var specsViewOptionsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Thumbnail View
            Button(action: {
                withAnimation(Motion.fade) {
                    specsDisplayMode = "thumbnail"
                }
            }) {
                HStack(spacing: 7) {
                    if specsDisplayMode == "thumbnail" {
                        Image(systemName: "checkmark")
                            .font(.system(size: StudioTheme.scaleFont(9.5), weight: .bold))
                            .foregroundColor(textMain)
                            .frame(width: 14, alignment: .center)
                    } else {
                        Spacer().frame(width: 14)
                    }
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                        .foregroundColor(textMain)
                        .frame(width: 16, alignment: .center)
                    Text("Thumbnail View")
                        .font(.system(size: StudioTheme.scaleFont(11.5), weight: .medium))
                        .foregroundColor(textMain)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // List View
            Button(action: {
                withAnimation(Motion.fade) {
                    specsDisplayMode = "inline"
                }
            }) {
                HStack(spacing: 7) {
                    if specsDisplayMode == "inline" {
                        Image(systemName: "checkmark")
                            .font(.system(size: StudioTheme.scaleFont(9.5), weight: .bold))
                            .foregroundColor(textMain)
                            .frame(width: 14, alignment: .center)
                    } else {
                        Spacer().frame(width: 14)
                    }
                    Image(systemName: "list.bullet")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                        .foregroundColor(textMain)
                        .frame(width: 16, alignment: .center)
                    Text("List View")
                        .font(.system(size: StudioTheme.scaleFont(11.5), weight: .medium))
                        .foregroundColor(textMain)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            Rectangle()
                .fill(borderLine.opacity(0.8))
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            
            // Thumbnail Size Slider
            Slider(
                value: Binding(
                    get: { specsThumbnailSize },
                    set: { newValue in
                        specsThumbnailSize = newValue
                        if specsDisplayMode != "thumbnail" {
                            specsDisplayMode = "thumbnail"
                        }
                    }
                ),
                in: 36...220
            )
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .padding(6)
        .frame(width: 185)
        .background(bgPanel)
    }
}


// MARK: - Row Skipping

/// Everything a Specs table row shows. Rows whose key is unchanged are not re-evaluated or re-diffed on a render.
struct SpecsRowKey: Equatable {
    let asset: DeliverableAsset
    let idx: Int
    let depth: Int
    let pathWidth: CGFloat
    let rowWidth: CGFloat
    let isTreeLayout: Bool
    let isSelected: Bool
    let isDismissed: Bool
    let hasSubtitleMismatch: Bool
    let srtURL: URL?
    let hasManualSrt: Bool
    let tag: FinderTagColor?
    let columnWidths: [Double]
    let displayMode: String
    let thumbnailWidth: Double
    let themeKey: String
    /// Selection / tag / subtitle state used by a multi-file right-click menu (0 when the row is not part of one).
    let menuContext: Int
    /// The file's Delivery Plan code and state (only rows whose plan info changed redraw).
    let plan: PlanFileInfo?
}

/// Renders `content` only when `key` changes (use with `.equatable()`).
struct EquatableRow<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content
    
    nonisolated static func == (lhs: EquatableRow, rhs: EquatableRow) -> Bool {
        MainActor.assumeIsolated { lhs.key == rhs.key }
    }
    
    var body: some View { content() }
}

// MARK: - End Frame Column

extension ContentView {
    var hasPendingEndFrameCheck: Bool {
        specsState.deliverableAssets.contains { $0.endFrame == nil }
    }
    
    @ViewBuilder
    func endFrameCell(_ check: EndFrameCheck?) -> some View {
        if let check {
            // Neutral on purpose: ending on black is a fact, not a pass or fail. A black swatch for BLACK, an empty one otherwise.
            HStack(spacing: 5) {
                if check.verdict != .unavailable {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(check.verdict == .black ? Color.black : Color.clear)
                        .frame(width: 8, height: 8)
                        .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(textMuted, lineWidth: 1))
                }
                Text(check.verdict.rawValue)
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(check.verdict == .unavailable ? textMuted : textMain)
                    .lineLimit(1)
            }
            .help(check.verdict == .unavailable
                  ? "No last frame to check (still image, audio, or the frame couldn't be decoded)"
                  : "Last frame \(check.timecode): \(String(format: "%.2f", 100 - check.litPercent))% black, \(String(format: "%.2f", check.litPercent))% picture/content (mean luma \(String(format: "%.1f", check.meanLuma)) / 255)")
        } else {
            Text("—")
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(textMuted)
                .help("Not checked yet: use CHECK END FRAMES")
        }
    }
    
}

/// Inspect's plan chip counts (states, batches, Frame.io), kept until the measured files or the plan's file index
/// change. A class held in `@State`: refreshing it doesn't trigger another render.
@MainActor
final class InspectPlanCounts {
    struct Summary {
        var states: [PlanState?: Int] = [:]
        var batches: [PlanBatchFilter.Item] = []
        var uploads = (none: 0, on: 0, stale: 0)
        var mismatches: [PlanMismatch: Int] = [:]
        /// Files with any mismatch (not-in-plan files count under their own chip).
        var mismatchTotal = 0
    }
    private var key: (Int, Int)?
    private var cached = Summary()

    func summary(assets: [DeliverableAsset], version: Int, files: [URL: PlanFileInfo], filesVersion: Int) -> Summary {
        if let key, key == (version, filesVersion) { return cached }
        var summary = Summary()
        var total: [String: Int] = [:], done: [String: Int] = [:], dropped: [String: Int] = [:]
        var uploads: [PlanUpload] = []
        for asset in assets {
            let info = files[asset.fileURL]
            summary.states[info?.state, default: 0] += 1
            guard let info, info.rowID != nil else { continue }
            total[info.batch, default: 0] += 1
            if info.state?.isDone == true { done[info.batch, default: 0] += 1 }
            if info.state == .dropped { dropped[info.batch, default: 0] += 1 }
            uploads.append(info.upload)
            for kind in info.mismatches { summary.mismatches[kind, default: 0] += 1 }
            if !info.mismatches.isEmpty { summary.mismatchTotal += 1 }
        }
        let names = PlanBatch.sorted(total.keys) + (total[""] != nil ? [""] : [])
        summary.batches = names.map { PlanBatchFilter.Item(name: $0, count: total[$0] ?? 0, done: done[$0] ?? 0, live: (total[$0] ?? 0) - (dropped[$0] ?? 0)) }
        summary.uploads = PlanUploadFilter.counts(uploads)
        key = (version, filesVersion)
        cached = summary
        return summary
    }
}

// MARK: - Group By

/// Inspect's Group By: the folder tree, a flat list, or the Delivery Plan's batch / status / channel.
enum InspectGrouping: String, CaseIterable {
    case folder, none, batch, status, channel

    var title: String {
        switch self {
        case .folder: return "Folder"
        case .none: return "None"
        case .batch: return "Batch"
        case .status: return "Status"
        case .channel: return "Channel"
        }
    }

    var needsPlan: Bool { self == .batch || self == .status || self == .channel }

    /// Status groups, problems first: what needs a look, then what's waiting, then what's done.
    static let statusOrder: [PlanState] = [.wrongSpec, .needsFix, .check, .toQC, .missing, .onHold, .passed, .approved, .delivered, .dropped]
}

extension ContentView {
    var inspectGrouping: InspectGrouping {
        let grouping = InspectGrouping(rawValue: inspectGroupBy) ?? .folder
        return grouping.needsPlan && planFiles.isEmpty ? .folder : grouping   // no plan linked: nothing to group by
    }

    /// Plan groups as one level of header nodes (ids "group:<kind>:<key>"), files in the list's order inside each.
    /// Cached until the files, filters, sort or plan index change (Inspect redraws on every selection).
    var planGroupTree: [FileSystemTreeNode] {
        let key = "\(inspectGrouping.rawValue)|\(specsState.assetsVersion)|\(planFilesVersion)|\(inspectPlanFilter)|\(inspectPlanBatch ?? "*")|\(inspectPlanUpload ?? -1)|\(inspectPlanSort)|\(specsState.specsSortColumnRaw)|\(specsState.specsSortAscending)|\(specsState.specsFilterText)|\(specsKindMask)"
        return inspectGroupCache.tree(key: key) { buildPlanGroupTree() }
    }

    private func buildPlanGroupTree() -> [FileSystemTreeNode] {
        let grouping = inspectGrouping
        var order: [String] = [], members: [String: [URL]] = [:], titles: [String: String] = [:]
        for asset in filteredDeliverableAssets {
            let info = planFiles[asset.fileURL]
            let key: String, title: String
            if info?.rowID == nil {
                key = "~notInPlan"; title = "Not in Plan"
            } else if let info {
                switch grouping {
                case .batch: (key, title) = info.batch.isEmpty ? ("~noBatch", "No Batch") : (info.batch, PlanBatch.title(info.batch))
                case .status: (key, title) = (info.state.map { String($0.rawValue) } ?? "~", info.state?.title ?? "Not in Plan")
                default: (key, title) = info.channel.isEmpty ? ("~noChannel", "No Channel") : (info.channel.lowercased(), info.channel)
                }
            } else { continue }
            if members[key] == nil { order.append(key); titles[key] = title }
            members[key, default: []].append(asset.fileURL)
        }
        // Groups in a meaningful order: batches by number, statuses problems first, channels by name; leftovers last.
        let batchOrder = Dictionary(uniqueKeysWithValues: PlanBatch.sorted(order.filter { !$0.hasPrefix("~") }).enumerated().map { ($0.element, $0.offset) })
        let rank: (String) -> (Int, String) = { key in
            if key.hasPrefix("~") { return (key == "~notInPlan" ? 3 : 2, key) }
            switch grouping {
            case .status:
                let state = Int(key).flatMap { PlanState(rawValue: $0) }
                return (0, String(format: "%02d", state.flatMap { InspectGrouping.statusOrder.firstIndex(of: $0) } ?? 99))
            case .batch:
                return (0, String(format: "%06d", batchOrder[key] ?? 0))
            default: return (0, key)
            }
        }
        let sortedKeys = order.sorted { rank($0) < rank($1) }
        let root = folderURL ?? URL(fileURLWithPath: "/")
        return sortedKeys.map { key in
            let urls = members[key] ?? []
            return FileSystemTreeNode(
                id: "group:\(grouping.rawValue):\(key)", name: titles[key] ?? key, url: root, isDirectory: true,
                relativePath: "", depth: 0,
                children: urls.map { FileSystemTreeNode(id: $0.path, name: $0.lastPathComponent, url: $0, isDirectory: false,
                                                        relativePath: $0.lastPathComponent, depth: 1) },
                videoURLs: urls)
        }
    }
}

/// Inspect's plan groups, kept for one key (a class in `@State`: storing doesn't trigger a render).
@MainActor
final class InspectGroupCache {
    private var key: String?
    private var cached: [FileSystemTreeNode] = []

    func tree(key: String, build: () -> [FileSystemTreeNode]) -> [FileSystemTreeNode] {
        if key == self.key { return cached }
        cached = build()
        self.key = key
        return cached
    }
}
