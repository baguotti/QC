import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 4: INGEST ====================
    
    var ingestTabView: some View {
        HSplitView {
            // Left Control Panel: Intake Setup, Checklist & Controls
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    // 01 INGEST INTAKE FOLDER
                    ingestFolderSection
                    
                    // 02 JOB HEADER (Checklist Section 1)
                    ingestJobHeaderSection
                    
                    // 03 ELEMENTS RECEIVED (Checklist Section 2)
                    ingestElementsSection
                    
                    // 04 FOOTAGE DETAILS (Checklist Section 3)
                    ingestFootageDetailsSection
                    
                    // 05 ATTRIBUTES & NOTES (Checklist Sections 4, 5, 6)
                    ingestAttributesSection
                    
                    // 06 DIT AUDIT & EXPORT
                    ingestDITAndExportSection
                }
                .padding(22)
            }
            .frame(minWidth: 380, idealWidth: 420, maxWidth: 460)
            .background(bgPanel)
            
            // Right Panel: Results, Discrepancies, and File Table
            VStack(alignment: .leading, spacing: 0) {
                if ingestState.isScanning {
                    ingestScanningOverlay
                } else if ingestState.manifest.items.isEmpty {
                    ingestEmptyStateView
                } else {
                    ingestResultsView
                }
            }
            .frame(minWidth: 560)
            .background(bgMain)
        }
        .onDrop(of: [UTType.fileURL, UTType.folder], isTargeted: nil) { providers in
            handleDrop(providers: providers, forTab: .ingest)
        }
    }
    
    // MARK: - Section 1: Ingest Intake Folder
    
    private var ingestFolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Intake Folder")
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button(action: { selectAssets(forTab: .ingest) }) {
                        HStack(spacing: 5) {
                            Image(systemName: ingestState.intakeFolderURL == nil ? "folder.badge.plus" : "arrow.triangle.2.circlepath")
                                .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                            Text(ingestState.intakeFolderURL == nil ? "Select Intake Folder" : "Change Folder")
                                .font(.ui(size: StudioTheme.scaleFont(9), weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    
                    if let folder = ingestState.intakeFolderURL {
                        Button(action: { ingestState.scanIntake(urls: [folder]) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 28)
                                .foregroundColor(textMain)
                                .studioBox(background: bgSubtle, border: borderLine)
                        }
                        .buttonStyle(.plain)
                        .explain("Rescan current intake folder")
                    }
                }
                
                if let folder = ingestState.intakeFolderURL {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        Text(folder.lastPathComponent)
                            .font(.ui(size: 10.5, weight: .semibold))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .studioBox(background: bgSubtle.opacity(0.5), border: borderLine.opacity(0.6))
                }
            }
        }
    }
    
    // MARK: - Section 2: Job Header
    
    private var ingestJobHeaderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Job Header")
            
            VStack(spacing: 7) {
                // Job Name / Number
                ingestFormField(label: "JOB NAME & NUMBER", placeholder: "e.g. 1953 - KM") {
                    TextField("", text: $ingestState.manifest.jobName)
                }
                
                // Ingested By & Date Row
                HStack(spacing: 8) {
                    ingestFormField(label: "INGESTED BY", placeholder: "Name / Initials") {
                        TextField("", text: $ingestState.manifest.ingestedBy)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Date Ingested")
                            .font(.ui(size: 8, weight: .semibold))
                            .foregroundColor(textMuted)
                        
                        DatePicker("", selection: $ingestState.manifest.dateIngested, displayedComponents: [.date])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .frame(height: 26)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // How was footage received
                ingestFormField(label: "HOW WAS FOOTAGE RECEIVED?", placeholder: "DROPBOX / HARD DRIVE / ASPERA") {
                    TextField("", text: $ingestState.manifest.receivedVia)
                }
                
                // Added to Client Drives Toggle
                HStack {
                    Text("Added to Client Drives")
                        .font(.ui(size: 8.5, weight: .semibold))
                        .foregroundColor(textMuted)
                    Spacer()
                    Button(action: { ingestState.manifest.addedToClientDrives.toggle() }) {
                        HStack(spacing: 5) {
                            Image(systemName: ingestState.manifest.addedToClientDrives ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11, weight: .bold))
                            Text(ingestState.manifest.addedToClientDrives ? "Yes" : "No")
                                .font(.ui(size: 10, weight: .semibold))
                        }
                        .foregroundColor(ingestState.manifest.addedToClientDrives ? accentBlue : textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .studioBox(
                            background: ingestState.manifest.addedToClientDrives ? accentBlue.opacity(0.12) : bgSubtle,
                            border: ingestState.manifest.addedToClientDrives ? accentBlue.opacity(0.5) : borderLine
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
    }
    
    // MARK: - Section 3: Elements Received (Checklist)
    
    private var ingestElementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Elements Received")
            
            VStack(spacing: 5) {
                ingestChecklistRow(
                    title: "Raw Footage",
                    icon: "film",
                    isChecked: $ingestState.manifest.hasRawFootage,
                    count: ingestState.manifest.items.filter { $0.fileCategory == .rawFootage }.count
                )
                ingestChecklistRow(
                    title: "Transcodes",
                    icon: "play.rectangle",
                    isChecked: $ingestState.manifest.hasTranscodes,
                    count: ingestState.manifest.items.filter { $0.fileCategory == .transcode }.count
                )
                ingestChecklistRow(
                    title: "Camera Reports",
                    icon: "doc.text",
                    isChecked: $ingestState.manifest.hasCameraReports,
                    count: ingestState.manifest.items.filter { $0.fileCategory == .cameraReport }.count
                )
                ingestChecklistRow(
                    title: "Location Audio",
                    icon: "waveform",
                    isChecked: $ingestState.manifest.hasLocationAudio,
                    count: ingestState.manifest.items.filter { $0.fileCategory == .locationAudio }.count
                )
                ingestChecklistRow(
                    title: "Shooting LUTs",
                    icon: "paintpalette",
                    isChecked: $ingestState.manifest.hasShootingLUTs,
                    count: ingestState.manifest.items.filter { $0.fileCategory == .lut }.count
                )
            }
        }
    }
    
    private func ingestChecklistRow(title: String, icon: String, isChecked: Binding<Bool>, count: Int) -> some View {
        Button(action: { isChecked.wrappedValue.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: isChecked.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isChecked.wrappedValue ? textMain : textMuted)
                
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(textMuted)
                    .frame(width: 14)
                
                Text(title)
                    .font(.ui(size: 10.5, weight: .medium))
                    .foregroundColor(textMain)
                
                Spacer()
                
                if count > 0 {
                    Text("\(count)")
                        .font(.ui(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundColor(textMain)
                        .studioBox(background: bgMain, border: borderLine)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .studioBox(
                background: isChecked.wrappedValue ? bgSubtle : bgSubtle.opacity(0.3),
                border: isChecked.wrappedValue ? borderStrong.opacity(0.6) : borderLine.opacity(0.5)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Section 4: Footage Details
    
    private var ingestFootageDetailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Footage Details")
            
            VStack(spacing: 7) {
                ingestFormField(label: "CAMERA USED (IF KNOWN)", placeholder: "e.g. ARRI Alexa 35, RED V-Raptor, Sony FX9") {
                    TextField("", text: $ingestState.manifest.cameraUsed)
                }
                
                HStack(spacing: 8) {
                    ingestFormField(label: "RAW MEDIA CODEC", placeholder: "e.g. ARRIRAW, ProRes 4444") {
                        TextField("", text: $ingestState.manifest.rawMediaCodec)
                    }
                    ingestFormField(label: "TRANSCODE CODEC", placeholder: "e.g. ProRes 422 Proxy, H.264") {
                        TextField("", text: $ingestState.manifest.transcodeCodec)
                    }
                }
                
                HStack(spacing: 8) {
                    ingestFormField(label: "SHOOTING RESOLUTION", placeholder: "e.g. 3840 x 2160, 4608 x 3164") {
                        TextField("", text: $ingestState.manifest.shootingResolution)
                    }
                    ingestFormField(label: "MAIN FPS / TIMEBASE", placeholder: "e.g. 24.00 fps, 25.00 fps") {
                        TextField("", text: $ingestState.manifest.mainFPS)
                    }
                }
            }
        }
    }
    
    // MARK: - Section 5: Attributes & Notes
    
    private var ingestAttributesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Attributes & Flags")
            
            VStack(spacing: 8) {
                // VFX Project Toggle
                HStack {
                    Text("Is this A vfx project?")
                        .font(.ui(size: 8.5, weight: .semibold))
                        .foregroundColor(textMuted)
                    Spacer()
                    HStack(spacing: 4) {
                        Button(action: { ingestState.manifest.isVFXProject = true }) {
                            Text("Yes")
                                .font(.ui(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .foregroundColor(ingestState.manifest.isVFXProject ? textMain : textMuted)
                                .studioBox(
                                    background: ingestState.manifest.isVFXProject ? bgSubtle : Color.clear,
                                    border: ingestState.manifest.isVFXProject ? borderStrong : borderLine
                                )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { ingestState.manifest.isVFXProject = false }) {
                            Text("No")
                                .font(.ui(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .foregroundColor(!ingestState.manifest.isVFXProject ? textMain : textMuted)
                                .studioBox(
                                    background: !ingestState.manifest.isVFXProject ? bgSubtle : Color.clear,
                                    border: !ingestState.manifest.isVFXProject ? borderStrong : borderLine
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // HD Source / Return to
                ingestFormField(label: "HD SOURCE / RETURN TO", placeholder: "Where did this HD come from / who to return to?") {
                    TextField("", text: $ingestState.manifest.hdSource)
                }
                
                // Free text Flags & Notes
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flags & Remarks")
                        .font(.ui(size: 8, weight: .semibold))
                        .foregroundColor(textMuted)
                    
                    TextField("Enter any notes, issues, or missing elements...", text: $ingestState.manifest.flagNotes)
                        .font(.ui(size: 10.5, weight: .medium))
                        .textFieldStyle(.plain)
                        .foregroundColor(textMain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
            }
        }
    }
    
    // MARK: - Section 6: DIT Cross-Reference & Export
    
    private var ingestDITAndExportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Dit & Export")
            
            VStack(spacing: 8) {
                // DIT Report Import
                if let url = ingestState.ditReportURL {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundColor(textMuted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.ui(size: 9.5, weight: .semibold))
                                .foregroundColor(textMain)
                                .lineLimit(1)
                            Text("\(ingestState.ditRecords.count) clips &bull; \(ingestState.flags.count) flags")
                                .font(.ui(size: 8.5))
                                .foregroundColor(ingestState.flags.isEmpty ? accentPositive : alertRed)
                        }
                        Spacer()
                        Button(action: { ingestState.clearDITReport() }) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12))
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .studioBox(background: bgSubtle, border: borderLine)
                } else {
                    Button(action: { ingestState.promptImportDITReport() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text("Cross-reference dit report (CSV / rtf / txt)")
                                .font(.ui(size: 9, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .explain("Import a DIT report (CSV, TSV, ALE, RTF, TXT) to verify files and flag missing or mismatched clips")
                }
                
                // Export Buttons Row
                HStack(spacing: 6) {
                    Button(action: { ingestState.exportManifestCSV() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("Save CSV")
                                .font(.ui(size: 9, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundColor(ingestState.manifest.items.isEmpty ? textMuted : textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(ingestState.manifest.items.isEmpty)
                    
                    Button(action: { ingestState.openManifestHTML() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("Open HTML")
                                .font(.ui(size: 9, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundColor(ingestState.manifest.items.isEmpty ? textMuted : textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(ingestState.manifest.items.isEmpty)
                    
                    Button(action: {
                        ingestState.copyManifestSummaryToClipboard()
                        showToast("Ingest summary copied to clipboard!")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("Copy")
                                .font(.ui(size: 9, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundColor(ingestState.manifest.items.isEmpty ? textMuted : textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(ingestState.manifest.items.isEmpty)
                }
            }
        }
    }
    
    // MARK: - Form Field Helper
    
    private func ingestFormField<Content: View>(label: String, placeholder: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.ui(size: 8, weight: .semibold))
                .foregroundColor(textMuted)
            
            content()
                .font(.ui(size: 10.5, weight: .medium))
                .textFieldStyle(.plain)
                .foregroundColor(textMain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .studioBox(background: bgSubtle, border: borderLine)
        }
    }
    
    // MARK: - Scanning Overlay
    
    private var ingestScanningOverlay: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: ingestState.scanProgress)
                .progressViewStyle(.linear)
                .frame(width: 320)
            
            Text("Analyzing Intake Footage")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(textMain)
            
            Text(ingestState.scanStatusMessage)
                .font(.ui(size: 11))
                .foregroundColor(textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Empty State View
    
    private var ingestEmptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 46, weight: .light))
                .foregroundColor(textMuted.opacity(0.5))
            
            Text("Drop Intake Folder Here")
                .font(.ui(size: 16, weight: .semibold))
                .foregroundColor(textMain)
            
            Text("Automatically catalog raw footage, transcodes, camera reports, audio, and LUTs.\nExtracts technical metadata and cross-references against DIT documentation.")
                .font(.ui(size: 11))
                .foregroundColor(textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 460)
            
            Button(action: { selectAssets(forTab: .ingest) }) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Select Intake Folder")
                        .font(.ui(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundColor(textMain)
                .studioBox(background: bgSubtle, border: borderStrong)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Results View
    
    private var ingestResultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Stats Bar
            HStack(spacing: 0) {
                let totalBytes = ingestState.manifest.items.reduce(0) { $0 + $1.fileSizeBytes }
                let rawCount = ingestState.manifest.items.filter { $0.fileCategory == .rawFootage }.count
                let transcodeCount = ingestState.manifest.items.filter { $0.fileCategory == .transcode }.count
                
                statBox(title: "Total Items", val: "\(ingestState.manifest.items.count)")
                statBox(title: "Total Size", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
                statBox(title: "Raw Clips", val: "\(rawCount)")
                statBox(title: "Transcodes", val: "\(transcodeCount)")
                
                if !ingestState.flags.isEmpty {
                    statBox(title: "Flags", val: "\(ingestState.flags.count)", isRed: true)
                } else if !ingestState.ditRecords.isEmpty {
                    statBox(title: "Dit Audit", val: "Verified", isPositive: true)
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(bgPanel)
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            // Search & Category Filter Toolbar
            HStack(spacing: 8) {
                // Search Input
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                    
                    TextField("Filter ingest items...", text: $ingestState.filterText)
                        .font(.ui(size: 10.5, weight: .medium))
                        .textFieldStyle(.plain)
                        .foregroundColor(textMain)
                    
                    if !ingestState.filterText.isEmpty {
                        Button(action: { ingestState.filterText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .studioBox(background: bgSubtle, border: borderLine)
                .frame(maxWidth: 240)
                
                // Category Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ingestCategoryFilterPill(title: "ALL", category: nil, count: ingestState.manifest.items.count)
                        ForEach(IngestFileCategory.allCases, id: \.self) { cat in
                            let count = ingestState.manifest.items.filter { $0.fileCategory == cat }.count
                            if count > 0 {
                                ingestCategoryFilterPill(title: cat.rawValue.uppercased(), category: cat, count: count)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(bgMain)
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            // Flags Banner (Collapsible)
            if !ingestState.flags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: { ingestState.isFlagsExpanded.toggle() }) {
                        HStack(spacing: 8) {
                            Image(systemName: ingestState.isFlagsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                            
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(alertRed)
                            
                            Text("Dit Audit Discrepancies (\(ingestState.flags.count))")
                                .font(.ui(size: 10.5, weight: .semibold))
                                .foregroundColor(alertRed)
                            
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if ingestState.isFlagsExpanded {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(ingestState.flags) { flag in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(flag.severity.rawValue)
                                            .font(.ui(size: 8, weight: .semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .foregroundColor(.white)
                                            .background(flag.severity == .critical ? alertRed : (flag.severity == .warning ? Color.orange : Color.blue))
                                            .cornerRadius(3)
                                        
                                        Text(flag.fileName)
                                            .font(.ui(size: 10, weight: .semibold))
                                            .foregroundColor(textMain)
                                        
                                        Text("&bull; \(flag.title): \(flag.detail)")
                                            .font(.ui(size: 10))
                                            .foregroundColor(textMuted)
                                        
                                        Spacer()
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(maxHeight: 110)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(alertRed.opacity(0.08))
                
                Rectangle()
                    .fill(alertRed.opacity(0.3))
                    .frame(height: 1)
            }
            
            // Table Header
            ingestTableHeaderView
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            // Items List
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(ingestState.filteredItems) { item in
                        ingestItemRow(item: item)
                        Rectangle()
                            .fill(borderLine.opacity(0.35))
                            .frame(height: 1)
                    }
                }
            }
        }
    }
    
    private func ingestCategoryFilterPill(title: String, category: IngestFileCategory?, count: Int) -> some View {
        let isSelected = (ingestState.selectedCategoryFilter == category)
        return Button(action: { ingestState.selectedCategoryFilter = category }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.ui(size: 8.5, weight: .semibold))
                Text("(\(count))")
                    .font(.ui(size: 8))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundColor(isSelected ? (isLightMode ? Color.black : Color.white) : textMuted)
            .studioBox(
                background: isSelected ? bgSubtle : Color.clear,
                border: isSelected ? borderStrong : borderLine.opacity(0.6)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Table Header
    
    private var ingestTableHeaderView: some View {
        HStack(spacing: 12) {
            ingestSortHeader(title: "CATEGORY", column: .category, width: 110)
            ingestSortHeader(title: "FILE NAME", column: .name, width: 220)
            ingestSortHeader(title: "PATH", column: .path, width: 140)
            ingestSortHeader(title: "SIZE", column: .size, width: 75)
            ingestSortHeader(title: "RES", column: .resolution, width: 100)
            ingestSortHeader(title: "FPS", column: .fps, width: 55)
            ingestSortHeader(title: "DUR", column: .duration, width: 70)
            ingestSortHeader(title: "CODEC", column: .codec, width: 120)
            Text("Audio")
                .font(.ui(size: 8.5, weight: .semibold))
                .foregroundColor(textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(bgPanel)
    }
    
    private func ingestSortHeader(title: String, column: IngestSortColumn, width: CGFloat) -> some View {
        Button(action: { ingestState.toggleSort(column) }) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.ui(size: 8.5, weight: .semibold))
                    .foregroundColor(ingestState.sortColumn == column ? textMain : textMuted)
                if ingestState.sortColumn == column {
                    Image(systemName: ingestState.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(textMain)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Item Row
    
    private func ingestItemRow(item: IngestItem) -> some View {
        let isSelected = (ingestState.selectedItem?.id == item.id)
        return HStack(spacing: 12) {
            // Category
            HStack(spacing: 5) {
                Image(systemName: item.fileCategory.iconName)
                    .font(.system(size: 9))
                    .foregroundColor(textMuted)
                Text(item.fileCategory.rawValue)
                    .font(.ui(size: 9.5, weight: .semibold))
                    .foregroundColor(textMain)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
            
            // Name
            Text(item.fileName)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(textMain)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 220, alignment: .leading)
            
            // Relative Path
            Text(item.relativePath)
                .font(.ui(size: 9.5))
                .foregroundColor(textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140, alignment: .leading)
            
            // Size
            Text(item.formattedFileSize)
                .font(.ui(size: 9.5))
                .foregroundColor(textMuted)
                .frame(width: 75, alignment: .leading)
            
            // Resolution
            Text(item.mediaMetadata?.resolutionString ?? "--")
                .font(.ui(size: 9.5))
                .foregroundColor(textMuted)
                .frame(width: 100, alignment: .leading)
            
            // FPS
            Text(item.mediaMetadata.map { String(format: "%.2f", $0.fps) } ?? "--")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(textMuted)
                .frame(width: 55, alignment: .leading)
            
            // Duration
            Text(item.mediaMetadata?.formattedDuration ?? "--")
                .font(.ui(size: 9.5))
                .foregroundColor(textMuted)
                .frame(width: 70, alignment: .leading)
            
            // Codec
            Text(item.mediaMetadata?.videoCodec ?? "--")
                .font(.ui(size: 9.5))
                .foregroundColor(textMuted)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            
            // Audio
            Text(item.mediaMetadata.map { "\($0.audioCodec) \($0.audioConfig)" } ?? "--")
                .font(.ui(size: 9.5))
                .foregroundColor(textMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(isSelected ? bgSubtle : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            ingestState.selectedItem = item
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            }
            Button("Copy File Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.fileURL.path, forType: .string)
            }
            if item.mediaMetadata != nil {
                Button("Open in Default Player") {
                    NSWorkspace.shared.open(item.fileURL)
                }
            }
        }
    }
}
