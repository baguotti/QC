import CoreMedia
import Testing
import VideoQCLib

@Suite("Timecode formatting edges")
struct TimecodeTests {
    @Test("Unusable times and rates format as zero instead of trapping")
    func unusableInputs() {
        #expect(TimecodeFormatter.format(time: .indefinite, fps: 25) == "00:00:00:00")
        #expect(TimecodeFormatter.format(time: .positiveInfinity, fps: 25) == "00:00:00:00")
        #expect(TimecodeFormatter.format(frameIndex: -3, fps: 25) == "00:00:00:00")
        #expect(TimecodeFormatter.format(frameIndex: 25, fps: .infinity) == "00:00:01:00")
    }
}

@Suite("Report escaping")
struct ReportEscapingTests {
    @Test("Names with markup characters stay text in HTML reports and their embedded CSV")
    func escaping() {
        #expect(QCUtilities.escapeHTML(#"Tom & "Jerry" <v2>.mov"#) == "Tom &amp; &quot;Jerry&quot; &lt;v2&gt;.mov")
        #expect(QCUtilities.escapeJSTemplate(#"a\b`c${d}</script>"#) == #"a\\b\`c\${d}<\/script>"#)
    }
}
