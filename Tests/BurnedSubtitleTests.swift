import AVFoundation
import AppKit
import Foundation
import Testing
@testable import VideoQCLib
@testable import QCpie

@Suite("Burned-in subtitles", .serialized)
struct BurnedSubtitleTests {
    typealias Change = BurnedSubtitleReader.Change

    @Test("Text distance: OCR noise is close, different lines are far, quote style doesn't count")
    func distance() {
        #expect(BurnedSubtitleReader.textDistance("couldn’t look after him.", "couldn't look after him") == 0)
        #expect(BurnedSubtitleReader.textDistance("When I was a child,", "When l was a chiId,") < 0.15)
        #expect(BurnedSubtitleReader.textDistance("When I was a child,", "my dad would light the fireplace") > 0.5)
        #expect(BurnedSubtitleReader.textDistance("", "") == 0)
        #expect(BurnedSubtitleReader.textDistance("", "a") == 1)
    }

    @Test("Changes become cues on exact frames; gaps end cues")
    func cuesFromChanges() {
        let changes = [Change(frame: 0, text: "", confidence: 0),
                       Change(frame: 24, text: "Hello there", confidence: 0.9),
                       Change(frame: 72, text: "", confidence: 0),
                       Change(frame: 96, text: "Second line", confidence: 0.9)]
        let r = BurnedSubtitleReader.result(from: changes, totalFrames: 240, fps: 24)
        #expect(r.cues.map(\.text) == ["Hello there", "Second line"])
        try? #require(r.cues.count == 2)
        guard r.cues.count == 2 else { return }
        #expect(r.cues[0].start == 1 && r.cues[0].end == 3)
        #expect(r.cues[1].start == 4 && r.cues[1].end == 10)   // runs to the clip's end
        #expect(r.lowConfidence.isEmpty && r.note == nil)
    }

    @Test("A wobble in the reading merges into one cue, keeping the clearest reading")
    func wobble() {
        let changes = [Change(frame: 0, text: "my mum would go and call", confidence: 0.5),
                       Change(frame: 30, text: "my mum would go and caII", confidence: 0.4),
                       Change(frame: 60, text: "", confidence: 0)]
        let r = BurnedSubtitleReader.result(from: changes, totalFrames: 100, fps: 24)
        #expect(r.cues.count == 1)
        #expect(r.cues.first?.text == "my mum would go and call" && r.cues.first?.end == 2.5)
        #expect(r.lowConfidence == [0])
    }

    @Test("Logos on screen most of a long clip and flashes are dropped; long text is kept but marked")
    func filters() {
        var changes: [Change] = [Change(frame: 0, text: "BRAND", confidence: 1)]
        changes.append(Change(frame: 200, text: "Real subtitle", confidence: 1))
        changes.append(Change(frame: 248, text: "BRAND", confidence: 1))
        changes.append(Change(frame: 900, text: "flash", confidence: 1))   // 3 frames: too short
        changes.append(Change(frame: 903, text: "BRAND", confidence: 1))
        let r = BurnedSubtitleReader.result(from: changes, totalFrames: 1000, fps: 24)
        #expect(r.cues.map(\.text) == ["Real subtitle"])
        let long = BurnedSubtitleReader.result(from: [Change(frame: 0, text: "Title card", confidence: 1),
                                                      Change(frame: 24 * 12, text: "", confidence: 0)], totalFrames: 24 * 60, fps: 24)
        #expect(long.cues.map(\.text) == ["Title card"] && long.lowConfidence == [0])
        // A 6 s social with one caption throughout keeps it.
        let social = BurnedSubtitleReader.result(from: [Change(frame: 0, text: "Shop the look", confidence: 1)], totalFrames: 150, fps: 25)
        #expect(social.cues.map(\.text) == ["Shop the look"])
    }

    @Test("Word-by-word captions are flagged")
    func wordByWord() {
        var changes: [Change] = []
        let words = "so today we are going to show you how to style the new jacket for every single day of the week".split(separator: " ")
        for i in 0..<20 { changes.append(Change(frame: i * 12, text: words[(i / 4) * 4...i].joined(separator: " "), confidence: 0.9)) }
        changes.append(Change(frame: 240, text: "", confidence: 0))
        let r = BurnedSubtitleReader.result(from: changes, totalFrames: 300, fps: 24)
        #expect(r.note?.contains("word by word") == true)
    }

    @Test("A stray dash on one line of two is removed; dialogue dashes on both lines stay")
    func dashes() {
        #expect(BurnedSubtitleReader.cleaned("- And he asked if we could send him\nmore things.") == "And he asked if we could send him\nmore things.")
        #expect(BurnedSubtitleReader.cleaned("- Are you coming?\n- Yes.") == "- Are you coming?\n- Yes.")
        #expect(BurnedSubtitleReader.cleaned("- Hello") == "Hello")
        #expect(BurnedSubtitleReader.cleaned("2-3 days") == "2-3 days")
        #expect(BurnedSubtitleReader.cleaned("-20 degrees\nout there") == "-20 degrees\nout there")
    }

    @Test("Empty or degenerate input gives no cues and no crash")
    func degenerate() {
        #expect(BurnedSubtitleReader.result(from: [], totalFrames: 0, fps: 24).cues.isEmpty)
        #expect(BurnedSubtitleReader.result(from: [Change(frame: 5, text: "x", confidence: 1)], totalFrames: 5, fps: 24).cues.isEmpty)
        #expect(BurnedSubtitleReader.result(from: [Change(frame: 0, text: "Hello", confidence: 1)], totalFrames: 48, fps: 0).cues.isEmpty)
    }

    // MARK: - End to end on a generated clip

    /// Writes a 25 fps clip whose lower third shows `subtitles` at known frames over a mid-grey picture.
    struct Style {
        var fontSize: CGFloat = 30
        var color = NSColor.white
        var box: NSColor? = nil
        var top = false
        /// Text on screen in every frame (a logo in the corner of the subtitle area).
        var logo: String? = nil
        var transform: CGAffineTransform = .identity
        /// Frames over which each subtitle fades in and out.
        var fade = 0
    }

    static func makeClip(_ subtitles: [(from: Int, to: Int, text: String)], frames: Int, size: CGSize = CGSize(width: 960, height: 540),
                         fps: Int32 = 25, frameDuration: Int64 = 1, style: Style = Style()) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burned-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        input.transform = style.transform
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(CGColor(gray: 0.35, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            if let logo = style.logo {
                NSAttributedString(string: logo, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.white])
                    .draw(at: CGPoint(x: size.width - 140, y: 20))
            }
            if let subtitle = subtitles.first(where: { frame >= $0.from && frame < $0.to }) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                var alpha: CGFloat = 1
                if style.fade > 0 {
                    let into = frame - subtitle.from, left = subtitle.to - 1 - frame
                    alpha = min(1, CGFloat(min(into, left) + 1) / CGFloat(style.fade + 1))
                }
                let text = NSAttributedString(string: subtitle.text, attributes: [
                    .font: NSFont.systemFont(ofSize: style.fontSize, weight: .medium), .foregroundColor: style.color.withAlphaComponent(alpha),
                    .paragraphStyle: paragraph,
                ])
                let height = text.boundingRect(with: CGSize(width: size.width, height: 1000), options: [.usesLineFragmentOrigin]).height
                let y = style.top ? size.height - 40 - height : 50
                if let box = style.box {
                    let width = text.boundingRect(with: CGSize(width: size.width, height: 1000), options: [.usesLineFragmentOrigin]).width
                    box.setFill()
                    CGRect(x: (size.width - width) / 2 - 10, y: y - 6, width: width + 20, height: height + 12).fill()
                }
                text.draw(in: CGRect(x: 0, y: y, width: size.width, height: height + 4))
            }
            NSGraphicsContext.restoreGraphicsState()
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(Int64(frame) * frameDuration), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return url
    }

    @Test("Generated clip: every subtitle read word for word, in and out on the exact frame")
    func endToEnd() async throws {
        let subtitles = [(from: 13, to: 61, text: "The first subtitle appears here"),
                         (from: 61, to: 107, text: "and the second follows straight on"),
                         (from: 140, to: 199, text: "A third one after a gap\nwith two lines")]
        let url = try Self.makeClip(subtitles, frames: 250)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await BurnedSubtitleReader().read(url, options: .init(languages: ["en-US"])) { _ in }
        #expect(result.cues.map(\.text) == subtitles.map(\.text))
        for (cue, expected) in zip(result.cues, subtitles) {
            #expect(abs(cue.start * 25 - Double(expected.from)) < 0.01, "start of \(expected.text)")
            #expect(abs(cue.end * 25 - Double(expected.to)) < 0.01, "end of \(expected.text)")
        }
    }

    @Test("Generated clip: nothing in the region gives a note, not a crash; top region reads nothing at the bottom")
    func emptyAndTop() async throws {
        let url = try Self.makeClip([(from: 0, to: 60, text: "Bottom text only")], frames: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let top = try await BurnedSubtitleReader().read(url, options: .init(region: .top, languages: ["en-US"])) { _ in }
        #expect(top.cues.isEmpty && top.note != nil)
        let blank = try Self.makeClip([], frames: 30)
        defer { try? FileManager.default.removeItem(at: blank) }
        let none = try await BurnedSubtitleReader().read(blank) { _ in }
        #expect(none.cues.isEmpty)
    }

    @Test("Cancelling stops the read with .cancelled")
    func cancel() async throws {
        let url = try Self.makeClip([(from: 0, to: 400, text: "Long subtitle")], frames: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BurnedSubtitleReader()
        reader.cancel()
        await #expect(throws: BurnedSubtitleReader.Failure.self) {
            _ = try await reader.read(url) { _ in }
        }
    }

    @Test("A file that isn't a video fails cleanly")
    func notVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-video-\(UUID().uuidString).mp4")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: BurnedSubtitleReader.Failure.self) {
            _ = try await BurnedSubtitleReader().read(url) { _ in }
        }
    }
}

@Suite("Subtitles read from the picture: the draft in the player", .serialized)
struct PictureSubtitleDraftTests {
    static func clip() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)/Clip 01.mov")
    }

    @Test @MainActor
    func draftLifecycle() throws {
        let engine = PlayerEngine()
        let clip = Self.clip()
        try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        engine.slotA.url = clip
        let cues = [SubtitleCue(start: 1, end: 2, text: "Hello"), SubtitleCue(start: 3, end: 4, text: "Wrold")]
        engine.loadPictureSubtitles(cues, review: [1], for: clip)

        #expect(engine.subtitleCues == cues)
        #expect(engine.pictureSubtitleClip == clip && engine.subtitleSourceURL == nil)
        #expect(engine.hasUnsavedSubtitleEdits && engine.subtitleReviewLines == [1])
        #expect(PlayerEngine.unsavedSubtitleFileNames.contains("Clip 01 (read from picture).srt"))

        // Edits stay in the draft (and survive the clip being shown again).
        engine.updateSubtitleText(at: 1, to: "World")
        engine.autoLoadSubtitles(for: clip)
        #expect(engine.subtitleCues[1].text == "World" && engine.pictureSubtitleClip == clip && engine.subtitleReviewLines == [1])

        // Saving writes the .srt, which becomes the source; the draft is gone from the quit prompt.
        let srt = clip.deletingPathExtension().appendingPathExtension("srt")
        try engine.saveSubtitles(to: srt)
        #expect(engine.subtitleSourceURL == srt && engine.pictureSubtitleClip == nil && !engine.hasUnsavedSubtitleEdits)
        #expect(engine.subtitleReviewLines.isEmpty)
        #expect(!PlayerEngine.unsavedSubtitleFileNames.contains("Clip 01 (read from picture).srt"))
        #expect(!engine.hasPictureSubtitleDraft(for: clip))
        #expect(try SubtitleParser.loadFile(from: srt).cues.map(\.text) == ["Hello", "World"])
    }

    @Test @MainActor
    func discardAndOtherClip() {
        let engine = PlayerEngine()
        let shown = Self.clip(), other = Self.clip()
        engine.slotA.url = shown
        // A read that finishes after the user moved to another clip is kept for that clip, not shown here.
        engine.loadPictureSubtitles([SubtitleCue(start: 0, end: 1, text: "Other")], review: [], for: other)
        #expect(engine.subtitleCues.isEmpty && engine.hasPictureSubtitleDraft(for: other))
        engine.slotA.url = other
        engine.autoLoadSubtitles(for: other)
        #expect(engine.subtitleCues.map(\.text) == ["Other"])
        // Remove Subtitles discards the draft for good; clearing on a clip change doesn't.
        engine.clearSubtitles()
        #expect(engine.hasPictureSubtitleDraft(for: other))
        engine.autoLoadSubtitles(for: other)
        engine.removeSubtitles()
        #expect(!engine.hasPictureSubtitleDraft(for: other) && engine.subtitleCues.isEmpty && engine.pictureSubtitleClip == nil)
    }

    @Test @MainActor
    func importingAnSRTOverADraft() throws {
        let engine = PlayerEngine()
        let clip = Self.clip()
        try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        engine.slotA.url = clip
        engine.loadPictureSubtitles([SubtitleCue(start: 0, end: 1, text: "Draft")], review: [0], for: clip)
        let srt = clip.deletingLastPathComponent().appendingPathComponent("supplied.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nSupplied\n".write(to: srt, atomically: true, encoding: .utf8)
        #expect(engine.loadSubtitles(from: srt))
        #expect(engine.subtitleCues.map(\.text) == ["Supplied"] && engine.pictureSubtitleClip == nil && engine.subtitleReviewLines.isEmpty)
        // Editing the file doesn't touch the draft, which is still there to come back to.
        engine.updateSubtitleText(at: 0, to: "Supplied 2")
        #expect(engine.hasPictureSubtitleDraft(for: clip))
        engine.removeSubtitles()   // a file: stays on disk, draft untouched
        #expect(FileManager.default.fileExists(atPath: srt.path) && engine.hasPictureSubtitleDraft(for: clip))
        engine.autoLoadSubtitles(for: clip)
        #expect(engine.subtitleCues.map(\.text) == ["Draft"])
        engine.removeSubtitles()
    }

    @Test("Comparison: quote style and two frames of timing don't count; wording, missing and extra lines do")
    func comparison() {
        let srt = [SubtitleCue(start: 1, end: 3, text: "couldn’t look after him."),
                   SubtitleCue(start: 3, end: 5, text: "Second line"),
                   SubtitleCue(start: 6, end: 8, text: "Third line")]
        let picture = [SubtitleCue(start: 1 + 2.0 / 24, end: 3, text: "couldn't look\nafter him."),
                       SubtitleCue(start: 3, end: 5, text: "Second lime"),
                       SubtitleCue(start: 9, end: 10, text: "Extra")]
        let c = PictureSubtitleComparison.make(srtName: "a.srt", srtCues: srt, picture: picture, fps: 24)
        #expect(c.differences.map(\.kind) == [.text, .missing, .extra])
        #expect(c.differingLines == [1, 2])
        let late = PictureSubtitleComparison.make(srtName: "a.srt", srtCues: [srt[0]],
                                                  picture: [SubtitleCue(start: 1 + 3.0 / 24, end: 3, text: srt[0].text)], fps: 24)
        #expect(late.differences.map(\.kind) == [.timing])
    }
}

@Suite("Burned-in subtitles: real-life clips", .serialized)
struct BurnedSubtitleRealLifeTests {
    typealias T = BurnedSubtitleTests

    func read(_ url: URL, _ options: BurnedSubtitleReader.Options = .init(languages: ["en-US"])) async throws -> BurnedSubtitleReader.Result {
        try await BurnedSubtitleReader().read(url, options: options) { _ in }
    }

    func expectFrames(_ cues: [SubtitleCue], _ expected: [(from: Int, to: Int, text: String)], fps: Double) {
        #expect(cues.map(\.text) == expected.map(\.text))
        for (cue, e) in zip(cues, expected) {
            #expect(abs(cue.start * fps - Double(e.from)) < 0.01, "start of \(e.text): \(cue.start * fps)")
            #expect(abs(cue.end * fps - Double(e.to)) < 0.01, "end of \(e.text): \(cue.end * fps)")
        }
    }

    @Test("One-word lines (No. / Yes.) are read, not filtered as specks")
    func oneWord() async throws {
        let subs = [(from: 10, to: 40, text: "No."), (from: 50, to: 80, text: "Yes.")]
        let url = try T.makeClip(subs, frames: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        expectFrames(try await read(url).cues, subs, fps: 25)
    }

    @Test("Portrait 9x16 with small captions")
    func portrait() async throws {
        let subs = [(from: 5, to: 50, text: "Shop the new collection"), (from: 50, to: 95, text: "Link in bio")]
        let url = try T.makeClip(subs, frames: 110, size: CGSize(width: 540, height: 960), style: .init(fontSize: 20))
        defer { try? FileManager.default.removeItem(at: url) }
        expectFrames(try await read(url).cues, subs, fps: 25)
    }

    @Test("A phone recording stored sideways with a rotation is read upright")
    func rotated() async throws {
        // Pixels stored 540 wide x 960 tall with the text drawn sideways would need a real camera; instead the
        // upright picture is stored with a 180° rotation, which the reader must undo.
        let subs = [(from: 5, to: 60, text: "Upside down storage")]
        let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 960, ty: 540)
        var style = T.Style(); style.transform = flip; style.top = true   // drawn at the top: upright, it's the bottom
        let url = try T.makeClip(subs, frames: 80, style: style)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BurnedSubtitleReader.orientation(of: flip) == .down)
        #expect(try await read(url).cues.map(\.text) == ["Upside down storage"])
    }

    @Test("29.97 fps: boundaries land on frames despite the 1001/30000 timebase")
    func ntsc() async throws {
        let subs = [(from: 17, to: 77, text: "Drop frame timing"), (from: 77, to: 140, text: "Second subtitle here")]
        let url = try T.makeClip(subs, frames: 160, fps: 30000, frameDuration: 1001)
        defer { try? FileManager.default.removeItem(at: url) }
        expectFrames(try await read(url).cues, subs, fps: 30000.0 / 1001.0)
    }

    @Test("Yellow text on a black box; top-of-picture subtitles")
    func styled() async throws {
        let subs = [(from: 10, to: 60, text: "Yellow captions on a box")]
        let boxed = try T.makeClip(subs, frames: 80, style: .init(color: .systemYellow, box: .black))
        let top = try T.makeClip(subs, frames: 80, style: .init(top: true))
        defer { try? FileManager.default.removeItem(at: boxed); try? FileManager.default.removeItem(at: top) }
        expectFrames(try await read(boxed).cues, subs, fps: 25)
        expectFrames(try await read(top, .init(region: .top, languages: ["en-US"])).cues, subs, fps: 25)
        #expect(try await read(top).cues.isEmpty)   // bottom region: nothing there
    }

    @Test("French with accents, language detected")
    func french() async throws {
        let subs = [(from: 10, to: 70, text: "Où est la gare, s'il vous plaît ?")]
        let url = try T.makeClip(subs, frames: 90)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try await read(url, .init(languages: []))
        #expect(r.cues.count == 1)
        #expect(BurnedSubtitleReader.textDistance(r.cues.first?.text ?? "", subs[0].text) < 0.1, "\(r.cues.first?.text ?? "-")")
    }

    @Test("A logo in the subtitle area all through a long clip is dropped; the subtitles stay")
    func logo() async throws {
        let subs = [(from: 100, to: 200, text: "A subtitle between logo frames"), (from: 600, to: 700, text: "Another subtitle later on")]
        let url = try T.makeClip(subs, frames: 25 * 35, size: CGSize(width: 640, height: 360), style: .init(fontSize: 22, logo: "BRAND"))
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try await read(url)
        #expect(!r.cues.contains { $0.text == "BRAND" }, "\(r.cues.map(\.text))")
        #expect(r.cues.contains { $0.text.contains("A subtitle between logo frames") })
    }

    @Test("Fades: in and out land within a few frames of where the text starts and ends")
    func fades() async throws {
        let subs = [(from: 20, to: 80, text: "Fading subtitle in and out"), (from: 100, to: 160, text: "Another fading line")]
        var style = T.Style(); style.fade = 6
        let url = try T.makeClip(subs, frames: 180, style: style)
        defer { try? FileManager.default.removeItem(at: url) }
        let cues = try await read(url).cues
        #expect(cues.map(\.text) == subs.map(\.text))
        for (cue, e) in zip(cues, subs) {
            #expect(abs(cue.start * 25 - Double(e.from)) <= 4, "start \(cue.start * 25) vs \(e.from)")
            #expect(abs(cue.end * 25 - Double(e.to)) <= 4, "end \(cue.end * 25) vs \(e.to)")
        }
    }

    @Test("Stopping mid-read returns promptly")
    func cancelMidway() async throws {
        let url = try T.makeClip([(from: 0, to: 600, text: "A long subtitle for a long time")], frames: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BurnedSubtitleReader()
        let started = Date()
        let task = Task { try await reader.read(url) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        reader.cancel()
        await #expect(throws: BurnedSubtitleReader.Failure.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test("A missing file says so")
    func missing() async {
        await #expect(throws: BurnedSubtitleReader.Failure.missing) {
            _ = try await BurnedSubtitleReader().read(URL(fileURLWithPath: "/nonexistent/clip.mp4")) { _ in }
        }
    }

    @Test("Decode size caps 4K at 1920 on the long side, even numbers; HD untouched")
    func decodeSize() {
        #expect(BurnedSubtitleReader.decodeSize(CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080))
        #expect(BurnedSubtitleReader.decodeSize(CGSize(width: 2160, height: 3840)) == CGSize(width: 1080, height: 1920))
        #expect(BurnedSubtitleReader.decodeSize(CGSize(width: 4096, height: 1716))?.height == 804)
        #expect(BurnedSubtitleReader.decodeSize(CGSize(width: 1920, height: 1080)) == nil)
    }
}

extension PictureSubtitleDraftTests {
    @Test @MainActor
    func attachingAnSRTInInspectShowsItOverTheDraft() async throws {
        let engine = PlayerEngine()
        let clip = Self.clip()
        try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        engine.slotA.url = clip
        engine.loadPictureSubtitles([SubtitleCue(start: 0, end: 1, text: "Draft")], review: [], for: clip)
        let srt = clip.deletingLastPathComponent().appendingPathComponent("attached.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nAttached\n".write(to: srt, atomically: true, encoding: .utf8)
        SubtitleAttachments.setManual(srt, for: clip)
        defer { SubtitleAttachments.setManual(nil, for: clip) }
        engine.autoLoadSubtitles(for: clip, preferDraft: SubtitleAttachments.manual(for: clip) == nil)
        try? await Task.sleep(for: .milliseconds(300))   // read off the main thread
        #expect(engine.subtitleCues.map(\.text) == ["Attached"])
        #expect(engine.hasPictureSubtitleDraft(for: clip))
        engine.removeSubtitles()
        engine.autoLoadSubtitles(for: clip)
        #expect(engine.subtitleCues.map(\.text) == ["Draft"])
        engine.removeSubtitles()
    }
}
