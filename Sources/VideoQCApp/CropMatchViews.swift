import SwiftUI
import VideoQCLib

/// Scan tab → Crop Match: the settings section, its progress, its results, and opening a shot pair in the Player.
extension ContentView {

    private var cropMatchVideos: [URL] { videoFiles.filter { QCUtilities.mediaKind(of: $0) == .video } }

    var cropMatchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Crop Match")

            checkCard {
                checkRow("What It Finds", divider: false) {
                    Text("Checks every cutdown against its master shot by shot: shots framed differently (moved or zoomed by a pixel or more) and shots that aren't in the master. Shots may be trimmed or retimed.")
                        .font(.ui(size: 11))
                        .foregroundColor(textSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                checkRow("Masters and Cutdowns") {
                    Text("Found from the names: versions of an edit share a name except their length, version and shape (\u{201C}EDIT_01_9x16_30s_E2.0\u{201D}, \u{201C}EDIT_01_9x16_06s_E1.0\u{201D}). Each set is one shape; its longest video is the master.")
                        .font(.ui(size: 11))
                        .foregroundColor(textSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if scannerState.isCropMatching {
                stopButton(scannerState.wasCropMatchCancelled ? "Stopping..." : "Stop Crop Match",
                           help: "Stops the crop match; cutdowns already compared keep their results.") {
                    scannerState.cancelCropMatch()
                }
            } else {
                runButton("Run Crop Match", icon: "crop",
                          isReady: cropMatchVideos.count >= 2 && !scannerState.isCheckRunning,
                          help: "Finds each master and its cutdowns in the batch and compares them shot by shot for framing.") {
                    scannerState.startCropMatch(videoFiles: videoFiles)
                }
            }
        }
    }

    var cropMatchProgressView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Matching Crops")
                .font(.system(size: StudioTheme.scaleFont(22), weight: .semibold))
                .foregroundColor(textMain)
            ObservingView(model: scannerState.progress) { progress in
                if let p = progress.crop {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(p.fileName)
                            .font(.ui(size: 15, weight: .semibold))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                        HStack(spacing: 20) {
                            statItem(label: "Batch Progress", val: "File \(String(format: "%02d", p.fileIndex)) / \(String(format: "%02d", p.totalFiles))", width: 140)
                            statItem(label: "Step", val: p.phase, width: 140)
                            statItem(label: "Done", val: "\(Int((p.fraction * 100).rounded()))%", width: 110)
                        }
                        GeometryReader { geo in
                            let ratio = (Double(p.fileIndex - 1) + p.fraction) / Double(max(1, p.totalFiles))
                            ZStack(alignment: .leading) {
                                Rectangle().fill(borderLine).frame(height: 4)
                                Rectangle().fill(primaryBtnBg).frame(width: geo.size.width * CGFloat(min(1, max(0, ratio))), height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(24)
                    .studioBox(background: bgPanel, border: borderLine)
                }
            }
            Spacer()
        }
        .padding(28)
    }

    @ViewBuilder
    var cropMatchResultsSection: some View {
        let batch = scannerState.cropMatchBatch
        let runs = batch?.runs ?? []
        let compared = runs.flatMap(\.results)

        resultsSectionTitle("Crop Match", status: resultsStatus(count: compared.count + runs.count, cancelled: scannerState.wasCropMatchCancelled)) {
            EmptyView()
        }
        // Across every set: shots reframed, not in the master and to check; masters and their cutdowns.
        HStack(spacing: 12) {
            let shots = compared.flatMap(\.shots)
            let reframed = shots.filter { $0.verdict == .reframed }.count
            let missing = shots.filter { $0.verdict == .notInMaster }.count
            let toCheck = shots.filter { if case .uncertain = $0.verdict { return true }; return false }.count
                + compared.filter { $0.readError != nil }.count
            statBox(title: "Masters", val: String(format: "%02d", runs.count))
            statBox(title: "Cutdowns", val: String(format: "%02d", compared.count))
            statBox(title: "Shots Reframed", val: String(format: "%02d", reframed), isRed: reframed > 0)
            statBox(title: "Not in Master", val: String(format: "%02d", missing), isRed: missing > 0)
            statBox(title: "To Check", val: String(format: "%02d", toCheck), isRed: toCheck > 0)
        }
        if let batch, !runs.isEmpty {
            let masters = Set(runs.map { $0.master.standardizedFileURL })
            CropMatchBatchView(batch: batch, isLightMode: isLightMode) { shot, result, master in
                openCropShot(shot, in: result, master: master, masters: masters)
            }
            .equatable()
        } else {
            VStack(spacing: 8) {
                Text("No Masters Found")
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundColor(textMain)
                Text(batch.map { $0.singles.isEmpty } ?? true
                     ? "Add masters and their cutdowns to the batch, then run Crop Match."
                     : "No two videos share a name apart from their length and version. Masters and cutdowns are matched by name.")
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundColor(textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .studioBox(background: bgPanel, border: borderLine)
        }
    }

    /// The cutdown shot in slot A and the master in slot B, linked at the measured frame pair, in Difference mode
    /// (framed alike, the picture reads black). Without a pair, just the cutdown shot.
    private func openCropShot(_ shot: CropMatchShot, in result: CropMatchResult, master: URL, masters: Set<URL>) {
        guard let c = shot.measuredCutdownFrame ?? (shot.masterStart != nil ? shot.start : nil),
              let m = shot.measuredMasterFrame ?? shot.masterStart else {
            // Nothing to compare with: a master left in slot B by an earlier Inspect would show a meaningless difference.
            // Only one of this run's masters is taken out; anything else the user put in slot B stays.
            if let inB = playerEngine.slotB.url?.standardizedFileURL, masters.contains(inB) { playerEngine.clearSlotB() }
            jumpToGlitchInPlayer(fileURL: result.fileURL, frameIndex: shot.start)
            return
        }
        jumpToGlitchInPlayer(fileURL: result.fileURL, frameIndex: c)
        playerEngine.loadVideo(url: master, into: .slotB)
        playerEngine.isLinked = true
        // Slot B plays at slot A's time plus the slip (in B's frames).
        let fpsA = max(1, result.fps), fpsB = max(1, result.masterFps)
        playerEngine.slotB.slipOffsetFrames = Int((Double(m) - Double(c) * fpsB / fpsA).rounded())
        playerEngine.compareMode = .difference
    }
}
