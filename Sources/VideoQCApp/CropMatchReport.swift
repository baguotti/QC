import SwiftUI
import VideoQCLib

/// One shot of one cutdown in a Crop Match run.
struct CropShotKey: Hashable {
    let file: URL
    let shot: Int
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
    private var compared: [CropMatchResult] { run.results.filter { $0.skipped == nil && $0.readError == nil } }

    var body: some View {
        let labels = Self.shortLabels([run.masterName] + run.results.map(\.fileName))
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

    private func card(_ result: CropMatchResult, labels: [String: String]) -> some View {
        let flagged = result.shots.filter { $0.verdict != .same }
        let matching = result.shots.count - flagged.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.fileName)
                        .font(.ui(size: 13, weight: .semibold))
                        .foregroundColor(palette.textMain)
                    if result.skipped == nil && result.readError == nil {
                        Text("\(FrameCheckAnalyzer.rateLabel(result.fps)) · \(result.shots.count) shot\(result.shots.count == 1 ? "" : "s")")
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundColor(palette.textMuted)
                    }
                }
                Spacer()
                Text(Self.verdict(result))
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(result.skipped != nil ? palette.textMuted : result.isFlagged ? palette.negative : palette.positive)
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

    private func row(_ shot: CropMatchShot, in result: CropMatchResult, labels: [String: String]) -> some View {
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
    private func expandedDetail(_ shot: CropMatchShot, in result: CropMatchResult, labels: [String: String]) -> some View {
        let masterFrame = shot.measuredMasterFrame ?? shot.masterStart ?? 0
        let versions = versionsOverlapping(shot)
        let aspect = run.masterSize.height > 0 ? run.masterSize.width / run.masterSize.height : 16 / 9
        let preview = CropBoxPreview(master: run.master, frame: masterFrame, fps: run.masterFps, aspect: aspect, isLightMode: isLightMode,
                                     boxes: versions.map { version in
                                         CropBoxPreview.Box(label: labels[version.result.fileName] ?? version.result.fileName,
                                                            rect: version.shot.cropRect(masterSize: run.masterSize),
                                                            color: Self.color(version.shot.verdict, palette))
                                     })
        let values = versionValues(versions, masterFrame: masterFrame, labels: labels)
        return VStack(alignment: .leading, spacing: 10) {
            // Side by side when the values fit beside the picture (they never wrap); otherwise below it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    preview.frame(width: 360)
                    values
                }
                VStack(alignment: .leading, spacing: 12) {
                    preview.frame(maxWidth: 360)
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
    private func versionValues(_ versions: [Version], masterFrame: Int, labels: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Master \(TimecodeFormatter.format(frameIndex: masterFrame, fps: run.masterFps)) · \(labels[run.masterName] ?? run.masterName) at 100%")
                .font(.ui(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(palette.textMuted)
            ForEach(versions, id: \.key) { version in
                let values = version.shot.editValues(masterSize: run.masterSize)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Self.color(version.shot.verdict, palette)).frame(width: 8, height: 8)
                    Text(labels[version.result.fileName] ?? version.result.fileName)
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
        if let skipped = result.skipped { return skipped }
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
            return [reason, masterTimecode, length].compactMap { $0 }.joined(separator: " · ")
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

    /// Each name without what all of them share ("Spot_16x9_10sec.mp4" → "10sec"), cut back to a word boundary.
    static func shortLabels(_ names: [String]) -> [String: String] {
        let stems = names.map { ($0 as NSString).deletingPathExtension }
        guard stems.count > 1, let first = stems.first else { return Dictionary(names.map { ($0, $0) }, uniquingKeysWith: { a, _ in a }) }
        let separators = CharacterSet(charactersIn: " _-.")
        var prefix = stems.dropFirst().reduce(first) { String($0.commonPrefix(with: $1)) }
        while let last = prefix.unicodeScalars.last, !separators.contains(last) { prefix.removeLast() }
        let reversed = stems.map { String($0.reversed()) }
        var suffix = String(reversed.dropFirst().reduce(reversed[0]) { String($0.commonPrefix(with: $1)) }.reversed())
        while let first = suffix.unicodeScalars.first, !separators.contains(first) { suffix.removeFirst() }
        var out: [String: String] = [:]
        for (name, stem) in zip(names, stems) {
            var label = stem
            if !prefix.isEmpty, label.hasPrefix(prefix) { label.removeFirst(prefix.count) }
            if !suffix.isEmpty, label.hasSuffix(suffix) { label.removeLast(suffix.count) }
            out[name] = label.isEmpty ? stem : label
        }
        return out
    }
}

// MARK: - Version map

/// The set at a glance on one time scale, under a seconds ruler: the master's bar (the stretches the cutdowns use) and
/// a bar per cutdown (its shots). Only problems carry colour (red reframed, amber check); shots framed as the master
/// are a quiet grey, shots not in the master hatched. Opened shots carry the accent outline; the hovered one is linked
/// to its master stretch (drawn under the bars) and named below. Clicking opens its row. One Canvas; only hover state
/// lives here.
private struct CropVersionMap: View {
    let run: CropMatchRun
    let compared: [CropMatchResult]
    let labels: [String: String]
    let expanded: Set<CropShotKey>
    let isLightMode: Bool
    let onSelect: (CropShotKey) -> Void

    @State private var hovered: CropShotKey?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private let barHeight: CGFloat = 16
    private let rowGap: CGFloat = 14
    private let rulerHeight: CGFloat = 18
    private var rowStep: CGFloat { barHeight + rowGap }

    private var seconds: Double {
        max(Double(run.masterFrames) / max(1, run.masterFps),
            compared.map { Double($0.totalFrames) / max(1, $0.fps) }.max() ?? 0, 0.001)
    }

    private var rows: [String] { [run.masterName] + compared.map(\.fileName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: rowGap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 4) {
                            if index == 0 {
                                Text("Master").font(.ui(size: 10)).foregroundColor(palette.textMuted)
                            }
                            Text(labels[name] ?? name)
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
                            case .active(let point): hovered = hit(point, width: geometry.size.width)
                            case .ended: hovered = nil
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
                }
                VStack(alignment: .leading, spacing: 6) {
                    captionText.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    legend
                }
            }
        }
        .padding(14)
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
        .explain("Each bar is a version on one time scale; on the master, the parts the cutdowns use. Hover a shot to see where it comes from; click it to see its crop.")
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

    private var caption: String {
        guard let key = hovered, let result = compared.first(where: { $0.fileURL == key.file }),
              let shot = result.shots.first(where: { $0.id == key.shot }) else {
            return "Hover a shot to see where it comes from in the master; click a coloured one to see its crop."
        }
        var parts = ["\(labels[result.fileName] ?? result.fileName) \(TimecodeFormatter.format(frameIndex: shot.start, fps: result.fps))",
                     CropMatchReport.kind(shot)]
        if shot.verdict == .reframed { parts.append(CropMatchReport.framing(shot)) }
        if let m = shot.masterStart { parts.append("Master \(TimecodeFormatter.format(frameIndex: m, fps: run.masterFps))") }
        if shot.verdict != .same { parts.append("click to see its crop") }
        return parts.joined(separator: " · ")
    }

    // MARK: Geometry

    private func x(_ frame: Int, fps: Double, width: CGFloat) -> CGFloat {
        CGFloat(Double(frame) / max(1, fps) / seconds) * width
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
        // The hovered shot's link first, so the bars draw over it.
        if let key = hovered, let row = compared.firstIndex(where: { $0.fileURL == key.file }),
           let shot = compared[row].shots.first(where: { $0.id == key.shot }), let a = shot.masterStart, let b = shot.masterEnd {
            let top = span(a, b, fps: run.masterFps, row: 0, width: width)
            let bottom = span(shot.start, shot.end, fps: compared[row].fps, row: row + 1, width: width)
            var link = Path()
            link.move(to: CGPoint(x: top.minX, y: top.maxY))
            link.addLine(to: CGPoint(x: top.maxX, y: top.maxY))
            link.addLine(to: CGPoint(x: bottom.maxX, y: bottom.minY))
            link.addLine(to: CGPoint(x: bottom.minX, y: bottom.minY))
            link.closeSubpath()
            context.fill(link, with: .color((shot.verdict == .same ? palette.textMuted : CropMatchReport.color(shot.verdict, palette)).opacity(0.16)))
        }
        // Master: its length, then the stretches the cutdowns use (problems drawn last, on top).
        let masterLength = CGRect(x: 0, y: rowY(0), width: x(run.masterFrames, fps: run.masterFps, width: width), height: barHeight)
        context.fill(block(masterLength), with: .color(palette.bgSubtle))
        // One fill per verdict: stretches used by several cutdowns don't stack their translucent grey.
        let all: [CropMatchShot] = compared.flatMap(\.shots)
        for verdict in [CropMatchShot.Verdict.same, .uncertain(""), .reframed] {
            var stretches = Path()
            for shot in all where shot.verdict.legendTitle == verdict.legendTitle {
                guard let a = shot.masterStart, let b = shot.masterEnd else { continue }
                stretches.addPath(block(span(a, b, fps: run.masterFps, row: 0, width: width)))
            }
            context.fill(stretches, with: .color(fill(verdict)))
        }
        // Cutdowns.
        for (index, result) in compared.enumerated() {
            let row = index + 1
            let length = CGRect(x: 0, y: rowY(row), width: x(result.totalFrames, fps: result.fps, width: width), height: barHeight)
            context.fill(block(length), with: .color(palette.bgSubtle))
            for shot in result.shots {
                let rect = span(shot.start, shot.end, fps: result.fps, row: row, width: width)
                context.fill(block(rect), with: .color(fill(shot.verdict)))
                if shot.verdict == .notInMaster { hatch(&context, rect) }
            }
        }
        // Outlines: opened shots in the accent (selection), the hovered one and its master stretch in the text colour.
        for (index, result) in compared.enumerated() {
            for shot in result.shots {
                let key = CropShotKey(file: result.fileURL, shot: shot.id)
                let isHovered = key == hovered
                guard isHovered || expanded.contains(key) else { continue }
                let colour = isHovered ? palette.textMain : palette.accentBlue
                context.stroke(block(span(shot.start, shot.end, fps: result.fps, row: index + 1, width: width).insetBy(dx: -1.5, dy: -1.5)),
                               with: .color(colour), lineWidth: 1.5)
                if isHovered, let a = shot.masterStart, let b = shot.masterEnd {
                    context.stroke(block(span(a, b, fps: run.masterFps, row: 0, width: width).insetBy(dx: -1.5, dy: -1.5)),
                                   with: .color(colour), lineWidth: 1.5)
                }
            }
        }
    }

    /// Seconds along the top: a tick per second (taller every 5), numbers every 5 s (every second under 6 s).
    private func drawRuler(_ context: inout GraphicsContext, width: CGFloat) {
        let total = Int(seconds.rounded(.down))
        let every = seconds < 6 ? 1 : 5
        for second in 0...max(0, total) {
            let px = CGFloat(Double(second) / seconds) * width
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
                                                                       targetSize: CGSize(width: 720, height: 720 / max(0.1, aspect)))
        }
    }
}
