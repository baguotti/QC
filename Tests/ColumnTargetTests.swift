import Foundation
import Testing
@testable import VideoQCLib

@Suite("Column targets")
struct ColumnTargetTests {
    private func asset(bytes: Int64 = 1, seconds: Double = 1, fps: Double = 25) -> DeliverableAsset {
        DeliverableAsset(fileURL: URL(fileURLWithPath: "/d/a.mov"), fileName: "a.mov", fileSizeBytes: bytes, formattedFileSize: "",
                         width: 1920, height: 1080, resolutionString: "", aspectRatioString: "16:9",
                         durationSeconds: seconds, formattedDuration: "",
                         totalFrames: Int((seconds * (fps > 0 ? fps : 25)).rounded()), timecode: "", fps: fps,
                         videoCodec: "H.264", audioConfig: "NONE", container: "MOV")
    }

    private func target(_ column: SpecsSortColumn, _ comparison: ColumnTarget.Comparison, _ text: String,
                        _ unit: ColumnTarget.Unit = .megabytes) -> ColumnTarget {
        ColumnTarget(column: column, comparison: comparison, text: text, unit: unit)!
    }

    @Test func sizeAtMostFlagsLargerFilesInDecimalUnits() {
        let t = target(.size, .atMost, "5")
        #expect(t.label == "≤ 5 MB")
        #expect(!t.flags(asset(bytes: 5_000_000)))
        #expect(t.flags(asset(bytes: 5_000_001)))
        #expect(target(.size, .atLeast, "1.5", .gigabytes).flags(asset(bytes: 1_499_999_999)))
        #expect(target(.size, .atMost, "0,5", .gigabytes).value == 500_000_000)   // comma decimal
    }

    @Test func bitRateUsesTheOverallRate() {
        let t = target(.bitrate, .atMost, "10", .megabitsPerSecond)
        #expect(!t.flags(asset(bytes: 1_250_000, seconds: 1)))   // exactly 10 Mbps
        #expect(t.flags(asset(bytes: 1_250_001, seconds: 1)))
    }

    @Test func frameRateEqualAllowsTheShownRounding() {
        let t = target(.fps, .equal, "23.98", .fps)
        #expect(!t.flags(asset(fps: 24000.0 / 1001.0)))
        #expect(t.flags(asset(fps: 24)))
        #expect(target(.fps, .equal, "25", .fps).flags(asset(fps: 29.97)))
        #expect(!target(.fps, .atLeast, "25", .fps).flags(asset(fps: 25)))
    }

    @Test func durationParsesSecondsAndClocks() {
        #expect(target(.timecode, .atMost, "30").value == 30)
        #expect(target(.timecode, .atMost, "1:30").value == 90)
        #expect(target(.timecode, .atMost, "01:00:00").value == 3600)
        #expect(target(.timecode, .atMost, "00:00:10:12").frames == 12)
    }

    @Test func durationComparesFramesAsTheTimecodeColumnShowsThem() {
        let spot = target(.timecode, .equal, "00:00:30:00")
        #expect(!spot.flags(asset(seconds: 30)))
        #expect(spot.flags(asset(seconds: 30 + 1.0 / 25)))   // one frame long
        #expect(spot.flags(asset(seconds: 30 - 1.0 / 25)))   // one frame short
        // 900 frames at 29.97 run 30.03 s but read 00:00:30:00; 720 at 23.976 likewise.
        #expect(!spot.flags(asset(seconds: 900 * 1001.0 / 30000, fps: 30000.0 / 1001)))
        #expect(!target(.timecode, .equal, "30").flags(asset(seconds: 720 * 1001.0 / 24000, fps: 24000.0 / 1001)))
        #expect(!target(.timecode, .atMost, "30").flags(asset(seconds: 900 * 1001.0 / 30000, fps: 30000.0 / 1001)))
        let withFrames = target(.timecode, .atMost, "00:00:10:12")
        #expect(!withFrames.flags(asset(seconds: 10.5, fps: 24)))   // 252 frames
        #expect(withFrames.flags(asset(seconds: 10.5 + 1.0 / 24, fps: 24)))
        #expect(!target(.timecode, .atLeast, "10").flags(asset(seconds: 10, fps: 0)))   // audio: 25 fps, as shown
    }

    @Test func rejectsWhatIsNotATarget() {
        for text in ["", "abc", "0", "-5", "1:2:3:4:5", "1::2", "00:00:00:00", "1.5:00", "1:75", "inf"] {
            #expect(ColumnTarget(column: text.contains(":") || text == "1.5:00" ? .timecode : .size, comparison: .atMost,
                                 text: text, unit: .megabytes) == nil, "\(text)")
        }
        #expect(ColumnTarget(column: .size, comparison: .equal, text: "5", unit: .megabytes) == nil)
        #expect(ColumnTarget(column: .videoCodec, comparison: .atMost, text: "5", unit: .megabytes) == nil)
    }

    @Test func filesWithoutTheValueAreNotFlagged() {
        let still = asset(seconds: 0, fps: 0)
        #expect(!target(.fps, .equal, "25", .fps).flags(still))
        #expect(!target(.timecode, .atLeast, "10").flags(still))
        #expect(!target(.bitrate, .atLeast, "10", .megabitsPerSecond).flags(still))
    }
}
