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
                    Text("Compares every cutdown with its master shot by shot: shots framed differently (moved or zoomed by a pixel or more) and shots that aren't in the master. Shots may be trimmed or retimed; videos of another shape are left out.")
                        .font(.ui(size: 11))
                        .foregroundColor(textSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                checkRow("Master") {
                    cropMasterMenu
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
                          help: "Compares each video with the master, shot by shot, for framing. Needs a master and at least one cutdown in the batch.") {
                    scannerState.startCropMatch(videoFiles: videoFiles)
                }
            }
        }
    }

    private var cropMasterMenu: some View {
        let chosen = scannerState.cropMatchMaster.flatMap { cropMatchVideos.contains($0) ? $0 : nil }
        return Menu {
            Picker("Master", selection: $scannerState.cropMatchMaster) {
                Text("Longest Video").tag(URL?.none)
                Divider()
                ForEach(cropMatchVideos, id: \.self) { url in
                    Text(url.lastPathComponent).tag(URL?.some(url))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(chosen?.lastPathComponent ?? "Longest Video")
                    .font(.ui(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
            }
            .foregroundColor(textMain)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(scannerState.isCheckRunning)
        .explain("The version the others were cut from. Longest Video picks the longest one in the batch; every other video of the same shape is compared with it.")
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
        let run = scannerState.cropMatchRun
        let results = run?.results ?? []
        let compared = results.filter { $0.skipped == nil }

        resultsSectionTitle("Crop Match", status: resultsStatus(count: compared.count, cancelled: scannerState.wasCropMatchCancelled)) {
            EmptyView()
        }
        if let run {
            Text("Master: \(run.masterName)")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(textSubtle)
                .explain(run.master.path)
        }
        // Versions compared and clean; shots reframed, not in the master and to check, across all of them.
        HStack(spacing: 12) {
            let shots = compared.flatMap(\.shots)
            let reframed = shots.filter { $0.verdict == .reframed }.count
            let missing = shots.filter { $0.verdict == .notInMaster }.count
            let toCheck = shots.filter { if case .uncertain = $0.verdict { return true }; return false }.count
                + compared.filter { $0.readError != nil }.count
            statBox(title: "Versions", val: String(format: "%02d", compared.count))
            statBox(title: "Shots Reframed", val: String(format: "%02d", reframed), isRed: reframed > 0)
            statBox(title: "Not in Master", val: String(format: "%02d", missing), isRed: missing > 0)
            statBox(title: "To Check", val: String(format: "%02d", toCheck), isRed: toCheck > 0)
            statBox(title: "Clean Versions", val: String(format: "%02d", compared.filter { !$0.isFlagged }.count),
                    isPositive: compared.contains { !$0.isFlagged })
        }
        if results.isEmpty {
            VStack(spacing: 8) {
                Text("Nothing Compared")
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundColor(textMain)
                Text("Add the master and its cutdowns to the batch, then run Crop Match.")
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundColor(textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .studioBox(background: bgPanel, border: borderLine)
        } else if let run {
            CropMatchReport(run: run, isLightMode: isLightMode) { shot, result in
                openCropShot(shot, in: result, master: run.master)
            }
            .equatable()
        }
    }

    /// The cutdown shot in slot A and the master in slot B, linked at the measured frame pair, in Difference mode
    /// (framed alike, the picture reads black). Without a pair, just the cutdown shot.
    private func openCropShot(_ shot: CropMatchShot, in result: CropMatchResult, master: URL) {
        guard let c = shot.measuredCutdownFrame ?? (shot.masterStart != nil ? shot.start : nil),
              let m = shot.measuredMasterFrame ?? shot.masterStart else {
            // Nothing to compare with: a master left in slot B by an earlier Inspect would show a meaningless difference.
            // Only this run's master is taken out; anything the user put in slot B stays.
            if playerEngine.slotB.url?.standardizedFileURL == master.standardizedFileURL { playerEngine.clearSlotB() }
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
