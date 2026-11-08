import Foundation
import JavaScriptCore
import Testing
@testable import VideoQCLib

/// File names are anything the file system allows: they must never break a report's HTML or its script.
@Suite("Report scripts")
struct ReportScriptTests {
    static let nastyNames = [#"back\slash \x41 \u00zz.mov"#, "</script><b>bold</b> & 'quote\".mov", "tick ` and ${x}.mp4"]

    /// The <script> blocks of a report, compiled (not run) by JavaScriptCore: nil when they're valid.
    static func scriptError(in html: String) -> String? {
        let context = JSContext()!
        var error: String?
        context.exceptionHandler = { _, value in error = value?.toString() }
        var rest = html[...]
        while let open = rest.range(of: "<script>"), let close = rest.range(of: "</script>", range: open.upperBound..<rest.endIndex) {
            let code = String(rest[open.upperBound..<close.lowerBound])
            context.setObject(code, forKeyedSubscript: "src" as NSString)
            context.evaluateScript("new Function(src)")   // compiles only
            if error != nil { return error }
            rest = rest[close.upperBound...]
        }
        return nil
    }

    @Test("Line Check report: odd file names keep the script valid and the markup intact")
    func lineCheckReport() {
        let results = Self.nastyNames.map { name in
            VideoQCResult(fileURL: URL(fileURLWithPath: "/d/\(name)"), fileName: name, resolution: "1920x1080", fps: 25,
                          totalFrames: 25, durationSeconds: 1, errorFrames: [])
        }
        let html = ReportWriter.generateHTMLReport(folderURL: URL(fileURLWithPath: "/d"), config: QCConfig(), results: results, csvFileName: #"report "x"\.csv"#)
        #expect(Self.scriptError(in: html) == nil)
        #expect(!html.contains("<b>bold</b>"))
    }

    @Test("Inspect report: odd file names keep the script valid and the markup intact")
    func inspectReport() {
        let assets = Self.nastyNames.map { name in
            DeliverableAsset(fileURL: URL(fileURLWithPath: "/d/\(name)"), fileName: name, fileSizeBytes: 1, formattedFileSize: "1 B",
                             width: 1920, height: 1080, resolutionString: "1920 x 1080", aspectRatioString: "16:9",
                             durationSeconds: 1, formattedDuration: "1.00s", totalFrames: 25, timecode: "00:00:01:00", fps: 25,
                             videoCodec: "H.264", audioConfig: "NONE", container: "MOV")
        }
        let html = DeliverablesInspector.generateManifestHTML(assets: assets, folderName: #"Folder </script> \x"#)
        #expect(Self.scriptError(in: html) == nil)
        #expect(!html.contains("<b>bold</b>"))
    }
}
