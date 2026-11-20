import Testing
import VideoQCLib

@Suite("Subtitle parsing")
struct SubtitleParserTests {
    @Test("A missing blank line doesn't merge the next cue into this one")
    func missingBlankLine() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello
        2
        00:00:03,000 --> 00:00:04,000
        World
        """
        let cues = SubtitleParser.parseSRT(srt)
        #expect(cues.map(\.text) == ["Hello", "World"])
        #expect(cues.map(\.start) == [1, 3])
    }

    @Test("A long cue stays on screen under later, shorter ones")
    func longOverlap() {
        let srt = """
        1
        00:00:00,000 --> 00:01:00,000
        Long

        2
        00:00:40,000 --> 00:00:41,000
        Short
        """
        let cues = SubtitleParser.parseSRT(srt)
        #expect(SubtitleParser.cueIndex(at: 40.5, in: cues) == 1)
        #expect(SubtitleParser.cueIndex(at: 50, in: cues) == 0)
        #expect(SubtitleParser.cueIndex(at: 61, in: cues) == nil)
    }

    @Test("Saving keeps zero-length cues; a cue without text isn't written (Premiere showed it as an empty box)")
    func roundTripKeepsEveryCue() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n2\n00:00:03,000 --> 00:00:03,000\nZero\n\n3\n00:00:04,000 --> 00:00:05,000\n\n4\n00:00:06,000 --> 00:00:07,000\nWorld\n"
        let cues = SubtitleParser.parseSRT(srt)
        #expect(cues.count == 4)
        let saved = SubtitleParser.serializeSRT(cues)
        #expect(SubtitleParser.parseSRT(saved).map(\.text) == ["Hello", "Zero", "World"])
        #expect(!saved.contains("\n\n\n") && saved.contains("3\n00:00:06,000 --> 00:00:07,000\nWorld"))
        // A line whose words were all deleted (tags left) goes too.
        #expect(!SubtitleParser.serializeSRT([SubtitleCue(start: 1, end: 2, text: "<i></i>")]).contains("-->"))
        // The blank cue is never what's on screen.
        #expect(SubtitleParser.cueIndex(at: 4.5, in: cues) == nil)
    }
}
