import SwiftUI
import VideoQCLib

/// One shot of one cutdown in a Crop Match run.
struct CropShotKey: Hashable {
    let file: URL
    let shot: Int
}

/// A Crop Match batch: with more than one set, a list of them (each with its verdict) to pick from, the first one with
/// a problem shown; then the picked set's header and report. Equal while the batch is the same; picking a set redraws
/// only this view.
struct CropMatchBatchView: View, Equatable {
    var themeRevision = ThemeManager.shared.revision
    let batch: CropMatchBatch
    let isLightMode: Bool
    let onInspect: (CropMatchShot, CropMatchResult, URL) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.batch.id == b.batch.id && a.isLightMode == b.isLightMode && a.themeRevision == b.themeRevision
    }

    @State private var selected: UUID?

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        let runs = batch.runs
        let current = runs.first { $0.id == selected } ?? runs.first(where: \.isFlagged) ?? runs[0]
        VStack(alignment: .leading, spacing: 16) {
            if runs.count > 1 { setList(runs, current: current.id) }
            VStack(alignment: .leading, spacing: 3) {
                Text(current.title.isEmpty ? current.masterName : current.title)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundColor(palette.textMain)
                Text("Master: \(current.masterName)")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .explain(current.master.path)
            CropMatchReport(run: current, isLightMode: isLightMode) { shot, result in onInspect(shot, result, current.master) }
                .equatable()
                .id(current.id)
            if !batch.singles.isEmpty { singles }
        }
        .onChange(of: batch.id) { selected = nil }
    }

    /// One row per set, Finder-sidebar style: the picked one on a soft fill with the accent bar.
    private func setList(_ runs: [CropMatchRun], current: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 { Rectangle().fill(palette.borderLine.opacity(0.6)).frame(height: 1) }
                setRow(run, isCurrent: run.id == current)
            }
        }
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
    }

    private func setRow(_ run: CropMatchRun, isCurrent: Bool) -> some View {
        let cutdowns = run.results.count
        let master = run.labels[run.master] ?? ""
        let shape = run.masterSize.height > 0 ? CropMatcher.ratio(Double(run.masterSize.width / run.masterSize.height)) : ""
        return HStack(spacing: 10) {
            Rectangle().fill(isCurrent ? palette.accentBlue : Color.clear).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title.isEmpty ? run.masterName : run.title)
                    .font(.ui(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(["Master \(master)", "\(cutdowns) cutdown\(cutdowns == 1 ? "" : "s")", shape].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(verdict(run))
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(run.isFlagged ? palette.negative : palette.positive)
                .lineLimit(1)
                .padding(.trailing, 14)
        }
        .padding(.vertical, 8)
        .background(isCurrent ? palette.bgSubtle : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.list) { selected = run.id } }
        .explain("Show this master and its cutdowns.")
    }

    private func verdict(_ run: CropMatchRun) -> String {
        let shots = run.results.flatMap(\.shots)
        let reframed = shots.filter { $0.verdict == .reframed }.count
        let missing = shots.filter { $0.verdict == .notInMaster }.count
        let check = shots.filter { if case .uncertain = $0.verdict { return true }; return false }.count
            + run.results.filter { $0.readError != nil }.count
        let parts = [reframed > 0 ? "\(reframed) reframed" : nil, missing > 0 ? "\(missing) not in master" : nil,
                     check > 0 ? "\(check) to check" : nil].compactMap { $0 }
        return parts.isEmpty ? "All framed as the master" : parts.joined(separator: " · ")
    }

    /// Videos with no other version in the batch: nothing to compare them with.
    private var singles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No Other Version (\(batch.singles.count))")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
            ForEach(batch.singles, id: \.self) { url in
                Text(url.lastPathComponent)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .explain(url.path)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
    }
}

/// Crop Match results under the stats: a version map of the whole set, then one card per cutdown whose flagged shots
/// expand into the master frame with every version's crop drawn on it. Its own view so expanding a row (or hovering
/// the map) redraws only the report, never the window; equal while the run is the same.
struct CropMatchReport: View, Equatable {
    /// Redraws on a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
    let run: CropMatchRun
    let isLightMode: Bool
    let onInspect: (CropMatchShot, CropMatchResult) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.run.id == b.run.id && a.isLightMode == b.isLightMode && a.themeRevision == b.themeRevision
    }

    @State private var expanded: Set<CropShotKey> = []

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var compared: [CropMatchResult] { run.results.filter { $0.readError == nil } }

    var body: some View {
        let labels = run.labels
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                if !compared.isEmpty {
                    CropVersionMap(run: run, compared: compared, labels: labels, expanded: expanded, isLightMode: isLightMode) { key in
                        withAnimation(Motion.list) {
                            expanded.insert(key)
                            proxy.scrollTo(key, anchor: .center)
                        }
                    }
                }
                ForEach(run.results) { result in
                    card(result, labels: labels)
                }
            }
            // A new run's shots reuse the same files and shot numbers: what was open belonged to the last one.
            .onChange(of: run.id) { expanded = [] }
            #if DEBUG
            // Screenshot mode: the first flagged shot opened, to capture its crop picture.
            .onAppear {
                guard UIShots.cropMatch, let result = compared.first(where: \.isFlagged),
                      let shot = result.shots.first(where: { $0.verdict != .same && $0.masterStart != nil }) else { return }
                expanded.insert(CropShotKey(file: result.fileURL, shot: shot.id))
            }
            #endif
        }
    }

    // MARK: Cards

    private func card(_ result: CropMatchResult, labels: [URL: String]) -> some View {
        let flagged = result.shots.filter { $0.verdict != .same }
        let matching = result.shots.count - flagged.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.fileName)
                        .font(.ui(size: 13, weight: .semibold))
                        .foregroundColor(palette.textMain)
                    if result.readError == nil {
                        Text("\(FrameCheckAnalyzer.rateLabel(result.fps)) · \(result.shots.count) shot\(result.shots.count == 1 ? "" : "s")")
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundColor(palette.textMuted)
                    }
                }
                Spacer()
                Text(Self.verdict(result))
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(result.isFlagged ? palette.negative : palette.positive)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 360, alignment: .trailing)
            }
            .padding(14)
            .background(palette.bgCardHeader)
            .explain(result.fileURL.path)

            if let readError = result.readError {
                Rectangle().fill(palette.borderLine).frame(height: 1)
                Text("Unreadable: \(readError).")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.negative)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            ForEach(flagged) { shot in
                Rectangle().fill(palette.borderLine.opacity(0.6)).frame(height: 1)
                row(shot, in: result, labels: labels)
            }
            if !flagged.isEmpty && matching > 0 {
                Rectangle().fill(palette.borderLine.opacity(0.6)).frame(height: 1)
                Text("\(matching) other shot\(matching == 1 ? "" : "s") framed as the master")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
        .overlay(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).stroke(result.isFlagged ? palette.negative : palette.borderLine, lineWidth: 1))
    }

    private func row(_ shot: CropMatchShot, in result: CropMatchResult, labels: [URL: String]) -> some View {
        let key = CropShotKey(file: result.fileURL, shot: shot.id)
        let isOpen = expanded.contains(key)
        let canOpen = shot.masterStart != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundColor(palette.textMuted)
                    .opacity(canOpen ? 1 : 0)
                    .frame(width: 10)
                Text(Self.kind(shot)).frame(width: 110, alignment: .leading).fontWeight(.semibold).foregroundColor(palette.textMain)
                Text(TimecodeFormatter.format(frameIndex: shot.start, fps: result.fps))
                    .frame(width: 100, alignment: .leading).fontWeight(.semibold).monospacedDigit().foregroundColor(palette.textMain)
                Text(Self.detail(shot, in: result)).lineLimit(1).foregroundColor(palette.textSubtle)
                Spacer(minLength: 8)
                Button(action: { onInspect(shot, result) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        Text("Inspect").font(.ui(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundColor(palette.primaryBtnFg)
                    .studioBox(background: palette.primaryBtnBg, border: palette.primaryBtnBg)
                }
                .buttonStyle(.plain)
                .explain(shot.measuredMasterFrame != nil
                         ? "Open this shot in the Player against the master's (A/B Difference: framed alike, the picture is black)."
                         : "Open this shot in the Player.")
            }
            .font(.ui(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canOpen else { return }
                withAnimation(Motion.list) {
                    if isOpen { expanded.remove(key) } else { expanded.insert(key) }
                }
            }
            .explain(canOpen ? "Show the master frame with each version's crop drawn on it." : "Not in the master: nothing to compare framing with.")

            if isOpen, canOpen {
                expandedDetail(shot, in: result, labels: labels)
                    .transition(.opacity)
            }
        }
        .id(key)
    }

    /// The master frame with the crop of every version using this stretch of the master, and each one's values.
    private func expandedDetail(_ shot: CropMatchShot, in result: CropMatchResult, labels: [URL: String]) -> some View {
        let masterFrame = shot.measuredMasterFrame ?? shot.masterStart ?? 0
        let versions = versionsOverlapping(shot)
        let aspect = run.masterSize.height > 0 ? run.masterSize.width / run.masterSize.height : 16 / 9
        let preview = CropBoxPreview(master: run.master, frame: masterFrame, fps: run.masterFps, aspect: aspect, isLightMode: isLightMode,
                                     boxes: versions.map { version in
                                         CropBoxPreview.Box(label: labels[version.result.fileURL] ?? version.result.fileName,
                                                            rect: version.shot.cropRect(masterSize: run.masterSize),
                                                            color: Self.color(version.shot.verdict, palette))
                                     })
        let values = versionValues(versions, masterFrame: masterFrame, labels: labels)
        // Long side 360 pt whatever the shape (a 9:16 master at 360 wide stood 640 tall).
        let previewSize = aspect >= 1 ? CGSize(width: 360, height: 360 / aspect) : CGSize(width: 360 * aspect, height: 360)
        return VStack(alignment: .leading, spacing: 10) {
            // Side by side when the values fit beside the picture (they never wrap); otherwise below it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    preview.frame(width: previewSize.width, height: previewSize.height)
                    values
                }
                VStack(alignment: .leading, spacing: 12) {
                    preview.frame(width: previewSize.width, height: previewSize.height)
                    values
                }
            }
            Text("Scale and Position as an editor's Motion settings would give each crop, on a \(Int(run.masterSize.width)) × \(Int(run.masterSize.height)) sequence with the master at 100%.")
                .font(.ui(size: 10))
                .foregroundColor(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// Each version's verdict and editor values, one line each (never wrapped).
    private func versionValues(_ versions: [Version], masterFrame: Int, labels: [URL: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Master \(TimecodeFormatter.format(frameIndex: masterFrame, fps: run.masterFps)) · \(labels[run.master] ?? run.masterName) at 100%")
                .font(.ui(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(palette.textMuted)
            ForEach(versions, id: \.key) { version in
                let values = version.shot.editValues(masterSize: run.masterSize)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Self.color(version.shot.verdict, palette)).frame(width: 8, height: 8)
                    Text(labels[version.result.fileURL] ?? version.result.fileName)
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(palette.textMain)
                        .frame(minWidth: 56, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.shot.verdict == .same ? "Framed as the master" : Self.kind(version.shot))
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundColor(version.shot.verdict == .same ? palette.textSubtle : Self.color(version.shot.verdict, palette))
                        Text(String(format: "Scale %.1f%% · Position %.1f, %.1f", values.scale, values.x, values.y))
                            .font(.ui(size: 11))
                            .monospacedDigit()
                            .foregroundColor(palette.textSubtle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .fixedSize()
    }

    private struct Version {
        let key: CropShotKey
        let result: CropMatchResult
        let shot: CropMatchShot
    }

    /// Every compared version's shots that use any of this shot's master frames, in the results' order.
    private func versionsOverlapping(_ shot: CropMatchShot) -> [Version] {
        guard let from = shot.masterStart, let to = shot.masterEnd else { return [] }
        return compared.flatMap { result in
            result.shots.compactMap { other -> Version? in
                guard let a = other.masterStart, let b = other.masterEnd, a <= to, b >= from else { return nil }
                return Version(key: CropShotKey(file: result.fileURL, shot: other.id), result: result, shot: other)
            }
        }
    }

    // MARK: Wording

    static func kind(_ shot: CropMatchShot) -> String {
        switch shot.verdict {
        case .same: return "Same Framing"
        case .reframed: return "Reframed"
        case .notInMaster: return "Not in Master"
        case .uncertain: return "Check"
        }
    }

    static func color(_ verdict: CropMatchShot.Verdict, _ palette: StudioPalette) -> Color {
        switch verdict {
        case .same: return palette.positive
        case .reframed: return palette.negative
        case .notInMaster: return palette.textMuted
        case .uncertain: return TagTone.amber.color(palette.isLight)
        }
    }

    static func verdict(_ result: CropMatchResult) -> String {
        if result.readError != nil { return "Couldn't be read" }
        guard result.isFlagged else {
            return result.shots.isEmpty ? "No shots found" : "All \(result.shots.count) shots framed as the master"
        }
        return [result.reframedCount > 0 ? "\(result.reframedCount) reframed" : nil,
                result.missingCount > 0 ? "\(result.missingCount) not in the master" : nil,
                result.uncertainCount > 0 ? "\(result.uncertainCount) to check" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "Master 00:00:12:04 · 105.0%, 19 px up · 22 frames"
    static func detail(_ shot: CropMatchShot, in result: CropMatchResult) -> String {
        let masterTimecode = (shot.measuredMasterFrame ?? shot.masterStart).map {
            "Master \(TimecodeFormatter.format(frameIndex: $0, fps: result.masterFps))"
        }
        let length = "\(shot.frameCount) frame\(shot.frameCount == 1 ? "" : "s")"
        switch shot.verdict {
        case .same:
            return [masterTimecode, length].compactMap { $0 }.joined(separator: " · ")
        case .reframed:
            return [masterTimecode, framing(shot), length].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .notInMaster:
            return "Not found in the master (another take, a new shot or a graphic) · \(length)"
        case .uncertain(let reason):
            // Measured framing too, when there is one ("about 108.2%, 23 px right"), so the eye knows what to look for.
            let measured = framing(shot)
            return [reason, measured.isEmpty ? nil : "about \(measured)", masterTimecode, length].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "105.0%, 19 px up": scale first (how editors set it), then the move in master pixels.
    static func framing(_ shot: CropMatchShot) -> String {
        var parts: [String] = []
        if abs(shot.scale - 1) >= 0.0005 { parts.append(String(format: "%.1f%%", shot.scale * 100)) }
        if abs(shot.shift.x) >= 0.5 { parts.append("\(Int(abs(shot.shift.x).rounded())) px \(shot.shift.x > 0 ? "right" : "left")") }
        if abs(shot.shift.y) >= 0.5 { parts.append("\(Int(abs(shot.shift.y).rounded())) px \(shot.shift.y > 0 ? "down" : "up")") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Version map

/// The set at a glance on one time scale, under a seconds ruler: the master's bar (the stretches the cutdowns use) and
/// a bar per cutdown (its shots). Only problems carry colour (red reframed, amber check); shots framed as the master
/// are a quiet grey, shots not in the master hatched. Opened shots carry the accent outline; the hovered one is linked
/// to its master stretch (drawn under the bars) and named below. Clicking opens its row. One Canvas; only hover state
/// lives here. Thumbnails mode (remembered) draws each shot's head frame on taller bars, Premiere-style, with the
/// verdict as a strip along the bottom; the frames come from the shared thumbnail cache, read in the background.
private struct CropVersionMap: View {
    let run: CropMatchRun
    let compared: [CropMatchResult]
    let labels: [URL: String]
    let expanded: Set<CropShotKey>
    let isLightMode: Bool
    let onSelect: (CropShotKey) -> Void

    @State private var hovered: CropShotKey?
    @AppStorage("cropMatchThumbnails") private var showThumbnails = false
    /// Head frames by `thumbKey`, filled in as they're read, for the run `thumbnailsRun` (a new run starts empty: a
    /// file re-exported at the same path has new frames).
    @State private var thumbnails: [String: CGImage] = [:]
    @State private var thumbnailsRun: UUID?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var barHeight: CGFloat { showThumbnails ? thumbnailBarHeight : 16 }
    /// Tall enough that a head frame is about 44 pt wide: 36 for landscape sets, up to 76 for 9:16 (at 36 pt a portrait
    /// frame was 20 pt wide, too small to tell shots apart).
    private var thumbnailBarHeight: CGFloat {
        let size = run.masterSize
        guard size.width > 0, size.height > 0 else { return 36 }
        return min(76, max(36, 44 * size.height / size.width))
    }
    /// The verdict strip under a thumbnail.
    private let stripHeight: CGFloat = 3
    private let rowGap: CGFloat = 14
    private let rulerHeight: CGFloat = 18
    private var rowStep: CGFloat { barHeight + rowGap }

    /// The time scale, worked out once (every coordinate uses it: a redraw does hundreds).
    private let seconds: Double

    init(run: CropMatchRun, compared: [CropMatchResult], labels: [URL: String], expanded: Set<CropShotKey>, isLightMode: Bool,
         onSelect: @escaping (CropShotKey) -> Void) {
        self.run = run
        self.compared = compared
        self.labels = labels
        self.expanded = expanded
        self.isLightMode = isLightMode
        self.onSelect = onSelect
        seconds = max(Double(run.masterFrames) / max(1, run.masterFps),
                      compared.map { Double($0.totalFrames) / max(1, $0.fps) }.max() ?? 0, 0.001)
    }

    private var rows: [URL] { [run.master] + compared.map(\.fileURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: rowGap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 4) {
                            if index == 0 {
                                Text("Master").font(.ui(size: 10)).foregroundColor(palette.textMuted)
                            }
                            Text(labels[url] ?? url.lastPathComponent)
                                .font(.ui(size: 11, weight: index == 0 ? .semibold : .medium))
                                .foregroundColor(index == 0 ? palette.textMain : palette.textSubtle)
                        }
                        .lineLimit(1)
                        .frame(height: barHeight)
                    }
                }
                .padding(.top, rulerHeight)
                .frame(minWidth: 48, maxWidth: 140, alignment: .trailing)
                GeometryReader { geometry in
                    Canvas { context, size in draw(&context, size: size) }
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            // Written only when the shot under the pointer changes: each write redraws the whole map
                            // (in Thumbnails mode, every head frame).
                            case .active(let point):
                                let key = hit(point, width: geometry.size.width)
                                if key != hovered { hovered = key }
                            case .ended: if hovered != nil { hovered = nil }
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { point in
                            // Only flagged shots have a row to open; the others are named on hover.
                            if let key = hit(point, width: geometry.size.width), isFlagged(key) { onSelect(key) }
                        }
                }
                // Room under the last bar for its outline.
                .frame(height: rulerHeight + rowStep * CGFloat(rows.count) - rowGap + 3)
            }
            Rectangle().fill(palette.borderLine).frame(height: 1)
            // The caption beside the key when both fit, else above it (never cut: it names the hovered shot).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    captionText.fixedSize()
                    Spacer(minLength: 8)
                    legend
                    viewToggle
                }
                VStack(alignment: .leading, spacing: 6) {
                    captionText.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        legend
                        Spacer(minLength: 8)
                        viewToggle
                    }
                }
            }
        }
        .padding(14)
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
        .explain("Each bar is a version on one time scale; on the master, the parts the cutdowns use. Hover a shot to see where it comes from; click it to see its crop.")
        .task(id: ThumbnailsLoad(run: run.id, on: showThumbnails)) {
            guard showThumbnails else { return }
            await loadThumbnails()
        }
        #if DEBUG
        // Screenshot mode: the opened shot in focus, as if hovered.
        .onChange(of: expanded) {
            guard UIShots.cropMatch, hovered == nil else { return }
            // QCPIE_FOCUS_ROW=n: the first flagged shot of cutdown n instead (a link crossing other rows).
            if let row = ProcessInfo.processInfo.environment["QCPIE_FOCUS_ROW"].flatMap(Int.init), row < compared.count,
               let shot = compared[row].shots.first(where: { $0.verdict != .same }) {
                hovered = CropShotKey(file: compared[row].fileURL, shot: shot.id)
            } else {
                hovered = expanded.first
            }
        }
        #endif
    }

    private var captionText: some View {
        Text(caption)
            .font(.ui(size: 11))
            .monospacedDigit()
            .foregroundColor(hovered == nil ? palette.textMuted : palette.textMain)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([CropMatchShot.Verdict.reframed, .uncertain(""), .notInMaster, .same], id: \.legendTitle) { verdict in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: Radius.control / 2)
                        .fill(fill(verdict))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control / 2)
                            .stroke(palette.textMuted.opacity(verdict == .notInMaster ? 0.6 : 0), lineWidth: 1))
                        .frame(width: 10, height: 8)
                    Text(verdict.legendTitle)
                        .font(.ui(size: 10))
                        .foregroundColor(palette.textMuted)
                }
            }
        }
        .fixedSize()
    }

    /// Shots (coloured blocks) or Thumbnails (head frames): a two-segment pill like the drawer tabs, compact.
    private var viewToggle: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { thumbs in
                let selected = showThumbnails == thumbs
                Button {
                    withAnimation(Motion.list) { showThumbnails = thumbs }
                } label: {
                    Image(systemName: thumbs ? "photo.on.rectangle" : "rectangle.split.3x1")
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                        .foregroundColor(selected ? palette.textMain : palette.textMuted)
                        .frame(width: StudioTheme.scale(26), height: StudioTheme.scale(18))
                        .background(RoundedRectangle(cornerRadius: Radius.segment)
                            .fill(selected ? palette.bgPanel : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: Radius.segment)
                            .stroke(selected ? palette.borderStrong : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(thumbs ? "Thumbnails: each shot's first frame." : "Shots: coloured blocks.")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgSubtle))
        .fixedSize()
    }

    private struct ThumbnailsLoad: Equatable {
        let run: UUID
        let on: Bool
    }

    private func thumbKey(_ url: URL, _ frame: Int) -> String { "\(url.path)#\(frame)" }

    /// The master stretches' and cutdown shots' head frames. Asked for all at once (the provider decodes a few at a
    /// time, off the main thread) and shown in batches, so the map isn't redrawn per frame.
    private func loadThumbnails() async {
        if thumbnailsRun != run.id {
            thumbnails = [:]
            thumbnailsRun = run.id
        }
        var wanted: [String: (url: URL, frame: Int, fps: Double)] = [:]
        for result in compared {
            for shot in result.shots {
                wanted[thumbKey(result.fileURL, shot.start)] = (result.fileURL, shot.start, result.fps)
                if let m = shot.masterStart { wanted[thumbKey(run.master, m)] = (run.master, m, run.masterFps) }
            }
        }
        for key in thumbnails.keys { wanted[key] = nil }
        guard !wanted.isEmpty else { return }
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for (key, item) in wanted {
                group.addTask {
                    (key, await GlitchThumbnailProvider.shared.getThumbnail(for: item.url, frameIndex: item.frame, fps: item.fps,
                                                                            targetSize: CGSize(width: 160, height: 160)))
                }
            }
            var pending: [String: CGImage] = [:]
            var lastShown = Date()
            for await (key, image) in group {
                if let image { pending[key] = image }
                if Date().timeIntervalSince(lastShown) > 0.15, !pending.isEmpty {
                    thumbnails.merge(pending) { $1 }
                    pending = [:]
                    lastShown = Date()
                }
            }
            if !pending.isEmpty, !Task.isCancelled { thumbnails.merge(pending) { $1 } }
        }
    }

    private var caption: String {
        guard let key = hovered, let result = compared.first(where: { $0.fileURL == key.file }),
              let shot = result.shots.first(where: { $0.id == key.shot }) else {
            return "Hover a shot to see where it comes from in the master; click a coloured one to see its crop."
        }
        var parts = ["\(labels[result.fileURL] ?? result.fileName) \(TimecodeFormatter.format(frameIndex: shot.start, fps: result.fps))",
                     CropMatchReport.kind(shot)]
        if shot.verdict == .reframed { parts.append(CropMatchReport.framing(shot)) }
        if let m = shot.masterStart { parts.append("Master \(TimecodeFormatter.format(frameIndex: m, fps: run.masterFps))") }
        if shot.verdict != .same { parts.append("click to see its crop") }
        return parts.joined(separator: " · ")
    }

    // MARK: Geometry

    /// Room either side of the bars, so an outline round the first or last shot isn't cut off.
    private let edge: CGFloat = 4

    private func x(_ frame: Int, fps: Double, width: CGFloat) -> CGFloat {
        x(seconds: Double(frame) / max(1, fps), width: width)
    }

    private func x(seconds time: Double, width: CGFloat) -> CGFloat {
        edge + CGFloat(time / seconds) * (width - 2 * edge)
    }

    private func rowY(_ row: Int) -> CGFloat { rulerHeight + CGFloat(row) * rowStep }

    /// Frames `first…last` on row `row`'s bar, a hairline in from each side (neighbouring shots stay apart).
    private func span(_ first: Int, _ last: Int, fps: Double, row: Int, width: CGFloat) -> CGRect {
        let left = x(first, fps: fps, width: width)
        let right = x(last + 1, fps: fps, width: width)
        let gap: CGFloat = right - left > 3 ? 0.75 : 0
        return CGRect(x: left + gap, y: rowY(row), width: max(1, right - left - 2 * gap), height: barHeight)
    }

    private func isFlagged(_ key: CropShotKey) -> Bool {
        compared.first { $0.fileURL == key.file }?.shots.first { $0.id == key.shot }.map { $0.verdict != .same } ?? false
    }

    private func hit(_ point: CGPoint, width: CGFloat) -> CropShotKey? {
        let row = Int((point.y - rulerHeight) / rowStep)
        guard point.y >= rulerHeight, row >= 1, row <= compared.count, point.y - rowY(row) <= barHeight else { return nil }
        let result = compared[row - 1]
        return result.shots.first { shot in
            point.x >= x(shot.start, fps: result.fps, width: width) && point.x <= x(shot.end + 1, fps: result.fps, width: width)
        }.map { CropShotKey(file: result.fileURL, shot: $0.id) }
    }

    // MARK: Drawing

    private func fill(_ verdict: CropMatchShot.Verdict) -> Color {
        switch verdict {
        case .same: return palette.textMuted.opacity(0.32)
        case .notInMaster: return palette.textMuted.opacity(0.14)
        default: return CropMatchReport.color(verdict, palette)
        }
    }

    private func block(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(Radius.control / 2, rect.width / 2))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        drawRuler(&context, width: width)
        // The hovered shot and its master stretch, if any: everything else dims while it's in focus.
        var focus: (shot: CropMatchShot, row: Int, rect: CGRect, master: CGRect?)?
        if let key = hovered, let index = compared.firstIndex(where: { $0.fileURL == key.file }),
           let shot = compared[index].shots.first(where: { $0.id == key.shot }) {
            let rect = span(shot.start, shot.end, fps: compared[index].fps, row: index + 1, width: width)
            let master = shot.masterStart.flatMap { a in shot.masterEnd.map { b in span(a, b, fps: run.masterFps, row: 0, width: width) } }
            focus = (shot, index + 1, rect, master)
        }
        // The link behind the timelines: it shows only between the bars.
        if let focus, let master = focus.master { drawLink(&context, from: master, to: focus.rect, verdict: focus.shot.verdict) }
        var rowBars: [CGRect] = []
        // Master: its length, then the stretches the cutdowns use (one fill per verdict: shared stretches don't stack).
        let masterLength = CGRect(x: edge, y: rowY(0), width: x(run.masterFrames, fps: run.masterFps, width: width) - edge, height: barHeight)
        context.fill(block(masterLength), with: .color(palette.bgSubtle))
        rowBars.append(masterLength)
        let all: [CropMatchShot] = compared.flatMap(\.shots)
        if showThumbnails {
            for shot in all {
                guard let a = shot.masterStart, let b = shot.masterEnd else { continue }
                drawThumbnail(&context, span(a, b, fps: run.masterFps, row: 0, width: width), verdict: shot.verdict,
                              image: thumbnails[thumbKey(run.master, a)])
            }
        } else {
            for verdict in [CropMatchShot.Verdict.same, .uncertain(""), .reframed] {
                var stretches = Path()
                for shot in all where shot.verdict.legendTitle == verdict.legendTitle {
                    guard let a = shot.masterStart, let b = shot.masterEnd else { continue }
                    stretches.addPath(block(span(a, b, fps: run.masterFps, row: 0, width: width)))
                }
                context.fill(stretches, with: .color(fill(verdict)))
            }
        }
        // Cutdowns.
        for (index, result) in compared.enumerated() {
            let row = index + 1
            let length = CGRect(x: edge, y: rowY(row), width: x(result.totalFrames, fps: result.fps, width: width) - edge, height: barHeight)
            context.fill(block(length), with: .color(palette.bgSubtle))
            rowBars.append(length)
            for shot in result.shots {
                drawShot(&context, span(shot.start, shot.end, fps: result.fps, row: row, width: width), verdict: shot.verdict,
                         image: thumbnails[thumbKey(result.fileURL, shot.start)])
            }
        }
        // In focus: a veil over the bars (dimming by opacity let overlapping stretches blend), then the pair redrawn on
        // top at full colour. The link was drawn first, behind everything.
        if let focus {
            // The veil covers the bars only, so the link between them stays clear.
            var veil = Path()
            for bar in rowBars { veil.addPath(block(bar)) }
            context.fill(veil, with: .color(palette.bgPanel.opacity(0.6)))
            if let master = focus.master, let start = focus.shot.masterStart {
                drawShot(&context, master, verdict: focus.shot.verdict, image: thumbnails[thumbKey(run.master, start)])
            }
            drawShot(&context, focus.rect, verdict: focus.shot.verdict,
                     image: thumbnails[thumbKey(compared[focus.row - 1].fileURL, focus.shot.start)])
        }
        // Opened shots: the accent outline (selection). The focused pair: a thin outline in the text colour.
        for (index, result) in compared.enumerated() {
            for shot in result.shots where expanded.contains(CropShotKey(file: result.fileURL, shot: shot.id)) {
                context.stroke(block(span(shot.start, shot.end, fps: result.fps, row: index + 1, width: width).insetBy(dx: -1.5, dy: -1.5)),
                               with: .color(palette.accentBlue), lineWidth: 1.5)
            }
        }
        if let focus {
            context.stroke(block(focus.rect.insetBy(dx: -1, dy: -1)), with: .color(palette.textMain.opacity(0.9)), lineWidth: 1)
            if let master = focus.master {
                context.stroke(block(master.insetBy(dx: -1, dy: -1)), with: .color(palette.textMain.opacity(0.9)), lineWidth: 1)
            }
        }
    }

    /// A shot as a coloured block, or in Thumbnails mode as its head frame with the verdict strip.
    private func drawShot(_ context: inout GraphicsContext, _ rect: CGRect, verdict: CropMatchShot.Verdict, image: CGImage?) {
        if showThumbnails {
            drawThumbnail(&context, rect, verdict: verdict, image: image)
        } else {
            context.fill(block(rect), with: .color(fill(verdict)))
            if verdict == .notInMaster { hatch(&context, rect) }
        }
    }

    /// The head frame at the shot's left, its height filling the bar, cut off where the shot ends (too narrow to read:
    /// none), on the bar's well; the verdict strip along the bottom.
    private func drawThumbnail(_ context: inout GraphicsContext, _ rect: CGRect, verdict: CropMatchShot.Verdict, image: CGImage?) {
        var clipped = context
        clipped.clip(to: block(rect))
        clipped.fill(Path(rect), with: .color(palette.bgSubtle))
        if let image, rect.width >= 10, image.height > 0 {
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            clipped.draw(Image(decorative: image, scale: 1), in: CGRect(x: rect.minX, y: rect.minY, width: rect.height * aspect, height: rect.height))
        }
        let strip = CGRect(x: rect.minX, y: rect.maxY - stripHeight, width: rect.width, height: stripHeight)
        clipped.fill(Path(strip), with: .color(verdict == .same ? palette.textMuted.opacity(0.5) : fill(verdict)))
        if verdict == .notInMaster { hatch(&clipped, strip) }
    }

    /// The link between a master stretch and a cutdown shot: two dotted lines from its edges, drawn behind the
    /// timelines (they show only between the bars).
    private func drawLink(_ context: inout GraphicsContext, from top: CGRect, to bottom: CGRect, verdict: CropMatchShot.Verdict) {
        let colour = verdict == .same ? palette.textMuted : CropMatchReport.color(verdict, palette)
        var edges = Path()
        edges.move(to: CGPoint(x: top.minX, y: top.maxY))
        edges.addLine(to: CGPoint(x: bottom.minX, y: bottom.minY))
        edges.move(to: CGPoint(x: top.maxX, y: top.maxY))
        edges.addLine(to: CGPoint(x: bottom.maxX, y: bottom.minY))
        context.stroke(edges, with: .color(colour.opacity(0.8)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 3]))
    }

    /// Seconds along the top: a tick per second (taller every 5), numbers every 5 s (every second under 6 s).
    private func drawRuler(_ context: inout GraphicsContext, width: CGFloat) {
        let total = Int(seconds.rounded(.down))
        let every = seconds < 6 ? 1 : 5
        for second in 0...max(0, total) {
            let px = x(seconds: Double(second), width: width)
            let major = second % every == 0
            var tick = Path()
            tick.move(to: CGPoint(x: px, y: rulerHeight - (major ? 6 : 3)))
            tick.addLine(to: CGPoint(x: px, y: rulerHeight - 1))
            context.stroke(tick, with: .color(palette.textMuted.opacity(major ? 0.6 : 0.3)), lineWidth: 1)
            guard major else { continue }
            let label = context.resolve(Text("\(second)s").font(.ui(size: 10)).foregroundColor(palette.textMuted))
            // The last one sits left of its tick, inside the ruler.
            let atEnd = px + label.measure(in: CGSize(width: 100, height: 20)).width + 2 > width
            context.draw(label, at: CGPoint(x: atEnd ? px - 2 : px + 2, y: 0), anchor: atEnd ? .topTrailing : .topLeading)
        }
    }

    /// Thin diagonal lines over a shot that isn't in the master.
    private func hatch(_ context: inout GraphicsContext, _ rect: CGRect) {
        var lines = Path()
        var x0 = rect.minX - rect.height
        while x0 < rect.maxX {
            lines.move(to: CGPoint(x: x0, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x0 + rect.height, y: rect.minY))
            x0 += 5
        }
        var clipped = context
        clipped.clip(to: block(rect))
        clipped.stroke(lines, with: .color(palette.textMuted.opacity(0.45)), lineWidth: 1)
    }
}

private extension CropMatchShot.Verdict {
    var legendTitle: String {
        switch self {
        case .reframed: return "Reframed"
        case .uncertain: return "Check"
        case .notInMaster: return "Not in master"
        case .same: return "As master"
        }
    }
}

// MARK: - Crop boxes

/// A master frame with crops drawn on it (fractions of the frame). The frame is decoded once it's on screen, through
/// the shared thumbnail cache.
struct CropBoxPreview: View {
    struct Box {
        let label: String
        let rect: CGRect
        let color: Color
    }

    let master: URL
    let frame: Int
    let fps: Double
    let aspect: CGFloat
    let isLightMode: Bool
    let boxes: [Box]

    @State private var image: CGImage?

    var body: some View {
        let palette = StudioPalette(isLightMode)
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Rectangle().fill(palette.bgSubtle)
            }
            GeometryReader { geometry in
                let size = geometry.size
                ForEach(Array(boxes.enumerated()), id: \.offset) { index, box in
                    let rect = CGRect(x: box.rect.minX * size.width, y: box.rect.minY * size.height,
                                      width: box.rect.width * size.width, height: box.rect.height * size.height)
                    // Boxes framed as the master lie on the frame's edge: drawn just inside it so they show.
                    let drawn = rect.insetBy(dx: 1.5 + CGFloat(index), dy: 1.5 + CGFloat(index))
                    Path(drawn).stroke(box.color, lineWidth: 2)
                    Text(box.label)
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(.white)   // design-ok: label drawn on the video frame
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(box.color)
                        .position(x: min(size.width - 30, max(30, drawn.minX + 30)),
                                  y: min(size.height - 8, max(8, drawn.minY + 9 + CGFloat(index) * 16)))
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .task(id: frame) {
            image = await GlitchThumbnailProvider.shared.getThumbnail(for: master, frameIndex: frame, fps: fps,
                                                                       targetSize: aspect >= 1 ? CGSize(width: 720, height: 720 / aspect)
                                                                                               : CGSize(width: 720 * aspect, height: 720))
        }
    }
}
