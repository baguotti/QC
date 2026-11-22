import Testing
@testable import VideoQCLib

@Suite("Subtitle cross-check") struct SubtitleCrossCheckTests {
    private func cue(_ start: Double, _ end: Double, _ text: String) -> SubtitleCue { SubtitleCue(start: start, end: end, text: text) }

    @Test func identicalFilesMatch() {
        let cues = [cue(0, 2, "A"), cue(2, 4, "B")]
        #expect(SubtitleCrossCheck.compare(reference: cues, other: cues).isEmpty)
    }

    // The line before a missing one touches the next line by a frame: that's a missing line, not a wording difference.
    @Test func missingLineBesideAnOverlap() {
        let diffs = SubtitleCrossCheck.compare(reference: [cue(0, 2, "A"), cue(2, 4, "B")], other: [cue(1.9, 4, "B")])
        #expect(diffs.map(\.kind) == [.missing, .timing])
        #expect(diffs.first?.referenceLine == 1)
    }

    @Test func extraLineBesideAnOverlap() {
        let diffs = SubtitleCrossCheck.compare(reference: [cue(1.9, 4, "B")], other: [cue(0, 2, "A"), cue(2, 4, "B")])
        #expect(diffs.map(\.kind) == [.extra, .timing])
    }

    @Test func rewordedLineIsAWordingDifference() {
        let diffs = SubtitleCrossCheck.compare(reference: [cue(0, 2, "Hello"), cue(2, 4, "B")], other: [cue(0, 2, "Helo"), cue(2, 4, "B")])
        #expect(diffs.map(\.kind) == [.text])
    }
}
