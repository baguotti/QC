import Foundation
import Testing
@testable import VideoQCLib

@Suite("Crop Match sets")
struct CropMatchSetTests {
    private func video(_ path: String, _ seconds: Double, aspect: Double = 9.0 / 16) -> CropMatchSets.Video {
        .init(url: URL(fileURLWithPath: "/Cafe/" + path), duration: seconds, aspect: aspect)
    }

    /// The "5_CAFE CLOSE-UPS" delivery as it came, all in one folder's worth (subfolders don't matter).
    private var cafe: [CropMatchSets.Video] {
        [video("Masters/Edit 5 Hero Video 5 - SS27_CAMPAIGN_DUO_PRODUCT FOCUS_20s_9x16_E3.0.mp4", 20),
         video("Masters/Edit 5A - SS27_CAMPAIGN_MSW_VIDEO EDIT_10s_9x16_E2.0.mp4", 10),
         video("Masters/Edit 5B - SS27_CAMPAIGN_WSW_BAG_VIDEO EDIT_10s_9x16_E2.0.mp4", 10),
         video("Masters/Edit 5C - SS27_CAMPAIGN_DUO_SUNGLASSES_OPTICAL_30s_9x16_E2.0.mp4", 30),
         video("Masters/Edit 5D - SS27_CAMPAIGN_DUO_SUNGLASSES_VIDEO EDIT_15s_9x16_E2.0.mp4", 15),
         video("Masters/Edit 5E - SS27_CAMPAIGN_DUO_OPTICAL_VIDEO EDIT_15s_9x16_E2.0.mp4", 15),
         video("Masters/Edit 5F - SS27_CAMPAIGN_DUO_FTW_ VIDEO EDIT_15s_9x16_E2.0.mp4", 15),
         video("Cutdowns/Edit 5 Hero Video 5 - SS27_CAMPAIGN_DUO_PRODUCT FOCUS_06s_9x16_E3.0.mp4", 6),
         video("Cutdowns/Edit 5 Hero Video 5 - SS27_CAMPAIGN_DUO_PRODUCT FOCUS_10s_9x16_E1.0.mp4", 10),
         video("Cutdowns/Edit 5 Hero Video 5 - SS27_CAMPAIGN_DUO_PRODUCT FOCUS_15s_9x16_E1.0.mp4", 15),
         video("Cutdowns/Edit 5B - SS27_CAMPAIGN_WSW_BAG_VIDEO EDIT_GIF_9x16_E1.1.mp4", 1.76),
         video("Cutdowns/Edit 5C - SS27_CAMPAIGN_DUO_SUNGLASSES_OPTICAL_06s_9x16_E2.0.mp4", 6),
         video("Cutdowns/Edit 5C - SS27_CAMPAIGN_DUO_SUNGLASSES_OPTICAL_10s_9x16_E1.0.mp4", 10.08),
         video("Cutdowns/Edit 5C - SS27_CAMPAIGN_DUO_SUNGLASSES_OPTICAL_GIF_9x16_E2.0.mp4", 3.84),
         video("Cutdowns/Edit 5D - SS27_CAMPAIGN_DUO_SUNGLASSES_VIDEO EDIT_15s_9x16_E2.0.mp4", 15),
         video("Cutdowns/Edit 5F - SS27_CAMPAIGN_DUO_FTW_VIDEO EDIT_GIF_9x16_E1.1.mp4", 2.64),
         video("Cutdowns/No longer needed>/Edit 5 Hero Video 5 - SS27_CAMPAIGN_DUO_PRODUCT FOCUS_GIF_9x16_E2.0.mp4", 1.28),
         video("Cutdowns/No longer needed>/Edit 5A - SS27_CAMPAIGN_MSW_VIDEO EDIT_GIF_9x16_E1.0.mp4", 1.36),
         video("Cutdowns/No longer needed>/Edit 5D - SS27_CAMPAIGN_DUO_SUNGLASSES_VIDEO EDIT_GIF_1.1.mp4", 2),
         video("Cutdowns/No longer needed>/Edit 5E - SS27_CAMPAIGN_DUO_OPTICAL_VIDEO EDIT_GIF_9x16_E1.1.mp4", 1.6)]
    }

    @Test("Each edit's versions form one set, its longest the master, whatever their version, length token or spacing")
    func cafeSets() {
        let (sets, singles) = CropMatchSets.sets(cafe.shuffled())
        #expect(singles.isEmpty)
        let summary = Dictionary(uniqueKeysWithValues: sets.map { set in
            (set.master.lastPathComponent.components(separatedBy: " - ")[0], set.cutdowns.count)
        })
        #expect(summary == ["Edit 5 Hero Video 5": 4, "Edit 5A": 1, "Edit 5B": 1, "Edit 5C": 3, "Edit 5D": 2, "Edit 5E": 1, "Edit 5F": 1])
        let five = try! #require(sets.first { $0.master.lastPathComponent.hasPrefix("Edit 5 Hero") })
        #expect(five.master.lastPathComponent.contains("_20s_"))
        #expect(five.labels[five.master] == "20s E3.0")
        #expect(five.cutdowns.compactMap { five.labels[$0] } == ["15s E1.0", "10s E1.0", "06s E3.0", "GIF E2.0"])
        // Two files of the same name (Masters and Cutdowns): the folder tells them apart.
        let d = try! #require(sets.first { $0.master.lastPathComponent.hasPrefix("Edit 5D") })
        #expect(d.labels.values.sorted() == ["15s E2.0 (Cutdowns)", "15s E2.0 (Masters)", "GIF 1.1"])
        // Equal lengths: the one in the Masters folder is the master.
        #expect(d.master.path.contains("/Masters/"))
        #expect(sets.map(\.title).first == "Edit 5 Hero Video 5 SS27 CAMPAIGN DUO PRODUCT FOCUS")
    }

    @Test("Numbers that name the edit stay; shape splits sets; a video with no other version is single")
    func edges() {
        let videos = [video("EDIT_01_AR_30sec.mov", 30), video("EDIT_01_AR_15sec.mov", 15),
                      video("EDIT_02_AR_30sec.mov", 30), video("EDIT_02_AR_06sec.mov", 6),
                      video("EDIT_01_AR_30sec_1x1.mov", 30, aspect: 1), video("EDIT_01_AR_10sec_1x1.mov", 10, aspect: 1),
                      video("Teaser_v3.mov", 12)]
        let (sets, singles) = CropMatchSets.sets(videos)
        #expect(sets.count == 3)
        #expect(Set(sets.map { "\($0.master.lastPathComponent)+\($0.cutdowns.count)" })
                == ["EDIT_01_AR_30sec.mov+1", "EDIT_02_AR_30sec.mov+1", "EDIT_01_AR_30sec_1x1.mov+1"])
        #expect(singles.map(\.lastPathComponent) == ["Teaser_v3.mov"])
        #expect(CropMatchSets.kind(of: ":30") == .length && CropMatchSets.kind(of: "06s") == .length && CropMatchSets.kind(of: "GIF") == .length)
        #expect(CropMatchSets.kind(of: "E1.0") == .version && CropMatchSets.kind(of: "1.1") == .version && CropMatchSets.kind(of: "v3") == .version)
        #expect(CropMatchSets.kind(of: "9x16") == .shape && CropMatchSets.kind(of: "01") == nil && CropMatchSets.kind(of: "5B") == nil)
        #expect(CropMatchSets.kind(of: "2.5s") == .length && CropMatchSets.kind(of: "30sec") == .length && CropMatchSets.kind(of: "1.91x1") == .shape)
        #expect(CropMatchSets.kind(of: "SS27") == nil && CropMatchSets.kind(of: "E") == nil && CropMatchSets.kind(of: "1.") == nil)
    }

    @Test("Masters by length to a tenth of a second (a consistent order), then a master folder, then the newest version")
    func masterOrder() {
        // 10.00 / 10.04 / 10.08 s: the old 0.05 s tolerance made the order depend on the input's.
        let a = video("Spot_10s_E1.0.mov", 10.00), b = video("Spot_10s_E1.1.mov", 10.04), c = video("Spot_10s_E2.0.mov", 10.08)
        let orders = [[a, b, c], [c, b, a], [b, a, c]].map { CropMatchSets.sets($0).sets.first?.master.lastPathComponent }
        #expect(Set(orders).count == 1)
        #expect(orders[0] == "Spot_10s_E2.0.mov")
        let same = [video("Spot_15s_E1.0.mov", 15), video("Spot_15s_E2.0.mov", 15)]
        #expect(CropMatchSets.sets(same).sets.first?.master.lastPathComponent == "Spot_15s_E2.0.mov")
    }
}
