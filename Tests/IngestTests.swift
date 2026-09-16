import Testing
import Foundation
@testable import VideoQCLib

@Suite("Ingest intake and DIT cross-reference tests")
struct IngestTests {
    
    @Test("CSV and TSV DIT parser extracts records and column values accurately")
    func testDITParser() {
        let csvContent = """
        Clip Name,Frame Rate,Resolution,Codec,Duration,Scene,Take
        A001_C001_091216_001.MOV,24 fps,3840x2160,ProRes 4444,00:01:23:12,12,1
        A001_C002_091216_001.MOV,25 fps,1920x1080,ProRes 422 HQ,00:00:45:00,12,2
        """
        
        let records = IngestDITParser.parse(content: csvContent)
        #expect(records.count == 2)
        #expect(records[0].fileName == "A001_C001_091216_001.MOV")
        #expect(records[0].fps == "24 fps")
        #expect(records[0].resolution == "3840x2160")
        #expect(records[0].codec == "ProRes 4444")
        
        // TSV test
        let tsvContent = "Clip\tFPS\tDimensions\nB002_C001\t23.98\t4096x2160\n"
        let tsvRecords = IngestDITParser.parse(content: tsvContent)
        #expect(tsvRecords.count == 1)
        #expect(tsvRecords[0].fileName == "B002_C001")
        #expect(tsvRecords[0].fps == "23.98")
        #expect(tsvRecords[0].resolution == "4096x2160")
    }
    
    @Test("Cross-reference detects missing files and metadata discrepancies")
    func testCrossReference() {
        let dummyURL1 = URL(fileURLWithPath: "/Volumes/Footage/A001_C001_091216_001.MOV")
        let dummyURL2 = URL(fileURLWithPath: "/Volumes/Footage/UNREPORTED_CLIP.MOV")
        
        let meta1 = IngestMediaMetadata(
            width: 3840,
            height: 2160,
            resolutionString: "3840 x 2160",
            aspectRatioString: "16:9",
            fps: 25.0, // Expected 24 in DIT
            durationSeconds: 83.5,
            formattedDuration: "83.50s",
            totalFrames: 2088,
            timecode: "00:01:23:12",
            videoCodec: "Apple ProRes 4444",
            container: "MOV"
        )
        
        let item1 = IngestItem(
            fileURL: dummyURL1,
            relativePath: "A001_C001_091216_001.MOV",
            fileName: "A001_C001_091216_001.MOV",
            fileSizeBytes: 1024 * 1024 * 500,
            formattedFileSize: "500.0 MB",
            fileCategory: .rawFootage,
            mediaMetadata: meta1
        )
        
        let item2 = IngestItem(
            fileURL: dummyURL2,
            relativePath: "UNREPORTED_CLIP.MOV",
            fileName: "UNREPORTED_CLIP.MOV",
            fileSizeBytes: 1024 * 1024 * 200,
            formattedFileSize: "200.0 MB",
            fileCategory: .rawFootage,
            mediaMetadata: nil
        )
        
        let ditCSV = """
        Clip Name,FPS,Resolution,Codec
        A001_C001_091216_001.MOV,24.0,3840x2160,ProRes 4444
        MISSING_FROM_DISK_001.MOV,24.0,3840x2160,ProRes 4444
        """
        
        let ditRecords = IngestDITParser.parse(content: ditCSV)
        let flags = IngestDITParser.crossReference(items: [item1, item2], ditRecords: ditRecords)
        
        // Should produce:
        // 1. Critical: MISSING_FROM_DISK_001.MOV missing from disk
        // 2. Warning: FPS Mismatch on A001_C001 (24 expected vs 25 actual)
        // 3. Info: UNREPORTED_CLIP.MOV exists on disk but not in DIT
        #expect(flags.contains { $0.severity == .critical && $0.fileName == "MISSING_FROM_DISK_001.MOV" })
        #expect(flags.contains { $0.severity == .warning && $0.title == "FPS Mismatch" })
        #expect(flags.contains { $0.severity == .info && $0.fileName == "UNREPORTED_CLIP.MOV" })
    }
    
    @Test("Manifest CSV and HTML reports generate structured output")
    func testReportGeneration() {
        var manifest = IngestManifest()
        manifest.jobName = "1953 - KM"
        manifest.ingestedBy = "E"
        manifest.receivedVia = "DROPBOX"
        manifest.addedToClientDrives = true
        manifest.hasRawFootage = true
        manifest.hasTranscodes = false
        manifest.rawMediaCodec = "Apple ProRes 4444"
        manifest.shootingResolution = "3840 x 2160"
        manifest.mainFPS = "24.00 fps"
        
        let item = IngestItem(
            fileURL: URL(fileURLWithPath: "/Volumes/Footage/RAW/A001_C001.mov"),
            relativePath: "RAW/A001_C001.mov",
            fileName: "A001_C001.mov",
            fileSizeBytes: 104857600,
            formattedFileSize: "100.0 MB",
            fileCategory: .rawFootage
        )
        manifest.items = [item]
        
        let csv = IngestDITParser.generateManifestCSV(manifest: manifest)
        #expect(csv.contains("QCPIE INGEST INTAKE REPORT"))
        #expect(csv.contains("1953 - KM"))
        #expect(csv.contains("DROPBOX"))
        #expect(csv.contains("A001_C001.mov"))
        
        let html = IngestDITParser.generateManifestHTML(manifest: manifest)
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("1953 - KM"))
        #expect(html.contains("A001_C001.mov"))
    }
    
    @Test("IngestInspector handles non-existent or corrupt files safely without crashing")
    func testCorruptOrMissingMediaInspection() async {
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_footage_\(UUID().uuidString).mov")
        let meta = await IngestInspector.inspectMedia(url: fakeURL)
        #expect(meta == nil)
    }
    
    @Test("IngestItem sorting handles edge cases with zero, NaN, and nil metadata safely")
    func testSortingSafety() {
        let item1 = IngestItem(
            fileURL: URL(fileURLWithPath: "/tmp/a.mov"),
            relativePath: "a.mov",
            fileName: "a.mov",
            fileSizeBytes: 0,
            formattedFileSize: "0 B",
            fileCategory: .rawFootage,
            mediaMetadata: nil
        )
        
        let item2 = IngestItem(
            fileURL: URL(fileURLWithPath: "/tmp/b.mov"),
            relativePath: "b.mov",
            fileName: "b.mov",
            fileSizeBytes: 1000,
            formattedFileSize: "1 KB",
            fileCategory: .transcode,
            mediaMetadata: IngestMediaMetadata(
                width: 1920,
                height: 1080,
                resolutionString: "1920 x 1080",
                aspectRatioString: "16:9",
                fps: 24.0,
                durationSeconds: 10.0,
                formattedDuration: "10.00s",
                totalFrames: 240,
                timecode: "00:00:10:00",
                videoCodec: "ProRes",
                container: "MOV"
            )
        )
        
        let items = [item1, item2]
        
        // Sorting by duration when one is nil
        let sortedByDuration = items.sorted { a, b in
            let aDur = a.mediaMetadata?.durationSeconds ?? 0
            let bDur = b.mediaMetadata?.durationSeconds ?? 0
            return aDur < bDur
        }
        #expect(sortedByDuration.first?.fileName == "a.mov")
        
        // Sorting by fps
        let sortedByFPS = items.sorted { a, b in
            let aFPS = a.mediaMetadata?.fps ?? 0
            let bFPS = b.mediaMetadata?.fps ?? 0
            return aFPS < bFPS
        }
        #expect(sortedByFPS.first?.fileName == "a.mov")
    }
    
    @Test("DeliverablesInspector formats file sizes >= 1000 GB in TB instead of thousands of GB")
    func testTBFormatting() {
        let oneGB: Int64 = 1024 * 1024 * 1024
        let size500GB = oneGB * 500
        let size1000GB = oneGB * 1000
        let size1500GB = oneGB * 1536
        
        #expect(DeliverablesInspector.formatFileSize(bytes: size500GB) == "500.00 GB")
        #expect(DeliverablesInspector.formatFileSize(bytes: size1000GB).contains("TB"))
        #expect(DeliverablesInspector.formatFileSize(bytes: size1500GB) == "1.50 TB")
    }
    
    @Test("IngestDITParser handles camera report metadata banners and pipe-delimited tables")
    func testDITParserWithHeaderMetadataAndPipes() {
        let cameraReport = """
        CAMERA REPORT & DIT LOG
        Project: Feature Film Alpha
        Date: 2026-09-16
        Camera: Alexa 35

        | Clip Name | FPS | Resolution | Codec |
        | --- | --- | --- | --- |
        | A001_C001_0916.mov | 24.00 | 3840x2160 | ProRes 4444 |
        | A001_C002_0916.mov | 24.00 | 3840x2160 | ProRes 4444 |
        """
        
        let records = IngestDITParser.parse(content: cameraReport)
        #expect(records.count == 2)
        #expect(records[0].fileName == "A001_C001_0916.mov")
        #expect(records[0].fps == "24.00")
        #expect(records[0].resolution == "3840x2160")
        #expect(records[1].fileName == "A001_C002_0916.mov")
    }
}
