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
}
