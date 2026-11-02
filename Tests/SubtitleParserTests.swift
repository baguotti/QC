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
}
