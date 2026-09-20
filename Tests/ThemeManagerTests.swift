import Foundation
import SwiftUI
import AppKit
import Testing
@testable import QCpie
@testable import VideoQCLib

@Suite("ThemeManager Custom Accents & Presets Tests")
struct ThemeManagerTests {
    
    @Test @MainActor
    func factoryPresetsAndLimits() {
        let manager = ThemeManager.shared
        manager.resetToDefault()
        
        #expect(ThemeManager.maxTotalPresets == 14)
        #expect(StudioThemeConfig.presets.count == 3)
        #expect(manager.currentTheme.id == StudioThemeConfig.muted.id)
        #expect(manager.canSaveMorePresets == true)
    }
    
    @Test @MainActor
    func updateColorDetachesToCustom() {
        let manager = ThemeManager.shared
        manager.applyTheme(StudioThemeConfig.muted)
        #expect(manager.currentTheme.isPreset == true)
        
        // Update slot A to bright neon green using new and legacy slot names
        manager.updateAccentColor(slot: .slota, hex: "#00FF88")
        
        #expect(manager.currentTheme.slotaHex == "#00FF88")
        #expect(manager.currentTheme.slotAHex == "#00FF88")
        #expect(manager.currentTheme.greenHex == "#00FF88") // backwards-compatible alias
        #expect(manager.currentTheme.name == "Custom")
        #expect(manager.currentTheme.isPreset == false)
        
        // Update slot B to cyan
        manager.updateAccentColor(slot: .slotB, hex: "#00FFFF")
        #expect(manager.currentTheme.slotBHex == "#00FFFF")
        #expect(manager.currentTheme.slobBHex == "#00FFFF")
        #expect(manager.currentTheme.purpleHex == "#00FFFF") // backwards-compatible alias
    }
    
    @Test @MainActor
    func saveAndLimitPresetsToFourteenTotal() {
        let manager = ThemeManager.shared
        // Clear existing user presets for test
        for preset in manager.userPresets {
            manager.deletePreset(id: preset.id)
        }
        
        #expect(manager.allThemes.count == 3)
        
        // Save presets up to the limit of 14 total (3 factory + 11 user)
        for i in 1...11 {
            let saved = manager.savePreset(name: "Test Theme \(i)")
            #expect(saved == true)
        }
        
        #expect(manager.allThemes.count == 14)
        #expect(manager.canSaveMorePresets == false)
        
        // 15th preset must be rejected
        let rejected = manager.savePreset(name: "Overflow Preset")
        #expect(rejected == false)
        #expect(manager.allThemes.count == 14)
        
        // Clean up test presets
        for preset in manager.userPresets {
            manager.deletePreset(id: preset.id)
        }
        #expect(manager.allThemes.count == 3)
    }
    
    @Test @MainActor
    func deletePresetFallsBackToDefaultWhenActive() {
        let manager = ThemeManager.shared
        manager.applyTheme(StudioThemeConfig.vivid)
        manager.updateAccentColor(slot: .play, hex: "#112233")
        
        let saved = manager.savePreset(name: "Temporary Preset")
        #expect(saved == true)
        let activeId = manager.currentTheme.id
        
        manager.deletePreset(id: activeId)
        #expect(manager.currentTheme.id == StudioThemeConfig.muted.id)
    }
    
    @Test @MainActor
    func cycleAccentThemeIncludesUserPresets() {
        let manager = ThemeManager.shared
        for preset in manager.userPresets {
            manager.deletePreset(id: preset.id)
        }
        
        _ = manager.savePreset(name: "Custom Cycle Preset")
        manager.applyTheme(StudioThemeConfig.warm)
        
        manager.cycleAccentTheme()
        #expect(manager.currentTheme.name == "Custom Cycle Preset")
        
        // Clean up
        for preset in manager.userPresets {
            manager.deletePreset(id: preset.id)
        }
    }
    
    @Test @MainActor
    func warmPresetProperties() {
        let preset = StudioThemeConfig.warm
        #expect(preset.name == "Warm")
        #expect(preset.id == "preset-warm")
        #expect(preset.playHex == "#E5A82E") // Warm yellow / amber playhead
        #expect(preset.blueHex == "#E5A82E") // Legacy alias
        #expect(preset.slotaHex == "#4E8C56")
        #expect(preset.slotBHex == "#825785")
        #expect(preset.warnHex == "#CC5238")
        
        // Backwards-compatible alias
        #expect(StudioThemeConfig.warmAmber.id == "preset-warm")
    }
    
    @Test @MainActor
    func droppedFrameIndicatorColorsAreFixedGreenAndRed() {
        // Must stay Green and Red independently of active theme
        #expect(StudioTheme.droppedFrameGreen == Color(hex: "#00EE9B"))
        #expect(StudioTheme.droppedFrameRed == Color(hex: "#FF4365"))
        
        let palette = StudioPalette(false)
        #expect(palette.droppedFrameGreen == Color(hex: "#00EE9B"))
        #expect(palette.droppedFrameRed == Color(hex: "#FF4365"))
    }

    @Test
    func legacyJsonDecodingCompatibility() throws {
        // Test decoding JSON encoded with legacy variable names (greenHex, blueHex, purpleHex, redHex)
        let legacyJSON = """
        {
            "id": "legacy-test-1",
            "name": "Legacy Theme",
            "isPreset": false,
            "greenHex": "#123456",
            "blueHex": "#234567",
            "purpleHex": "#345678",
            "redHex": "#456789",
            "lightGreenHex": "#56789A",
            "lightBlueHex": "#6789AB",
            "lightPurpleHex": "#789ABC",
            "lightRedHex": "#89ABCD"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let theme = try decoder.decode(StudioThemeConfig.self, from: legacyJSON)
        
        #expect(theme.slotaHex == "#123456")
        #expect(theme.playHex == "#234567")
        #expect(theme.slotBHex == "#345678")
        #expect(theme.slobBHex == "#345678")
        #expect(theme.warnHex == "#456789")
        #expect(theme.lightSlotaHex == "#56789A")
        #expect(theme.lightPlayHex == "#6789AB")
        #expect(theme.lightSlotBHex == "#789ABC")
        #expect(theme.lightWarnHex == "#89ABCD")
    }
}

@Suite("Specs Mismatch Dismissal and Scanner Tests")
struct SpecsAndScannerTests {
    
    @Test @MainActor
    func specsMismatchDismissalToggle() {
        let specs = SpecsState()
        let url = URL(fileURLWithPath: "/Volumes/Deliverables/Commercial_30s_16x9.mov")
        
        #expect(specs.isMismatchDismissed(for: url) == false)
        
        specs.dismissMismatch(for: url)
        #expect(specs.isMismatchDismissed(for: url) == true)
        
        specs.restoreMismatch(for: url)
        #expect(specs.isMismatchDismissed(for: url) == false)
        
        specs.toggleDismissMismatch(for: url)
        #expect(specs.isMismatchDismissed(for: url) == true)
        
        specs.toggleDismissMismatch(for: url)
        #expect(specs.isMismatchDismissed(for: url) == false)
    }
    
    @Test @MainActor
    func scannerStateDefaultsAndCancel() {
        let scanner = ScannerState()
        #expect(scanner.tagInFinder == false)
        #expect(scanner.wasScanCancelled == false)
        #expect(scanner.isCancelling == false)
        
        // Simulating cancellation call when not scanning
        scanner.cancelScan()
        #expect(scanner.wasScanCancelled == false)
        
        // Simulating cancellation call when scanning
        scanner.isScanning = true
        scanner.cancelScan()
        #expect(scanner.wasScanCancelled == true)
        #expect(scanner.isCancelling == true)
    }
    
    @Test @MainActor
    func keyboardShortcutRouterSleeveAndIngestRules() {
        var ingestTabCalled = false
        var leftSleeveCalled = false
        var rightSleeveCalled = false
        var propertiesCalled = false
        
        let actions = KeyboardShortcutActions(
            onSelectIngestTab: { ingestTabCalled = true },
            onToggleProperties: { propertiesCalled = true },
            onToggleLeftSleeve: { leftSleeveCalled = true },
            onToggleRightSleeve: { rightSleeveCalled = true }
        )
        
        let router = KeyboardShortcutRouter.standardRouter(actions: actions)
        
        // 1. Shift + 4 (keyCode 21) -> Ingest tab
        let shift4Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "$",
            charactersIgnoringModifiers: "4",
            isARepeat: false,
            keyCode: 21
        )!
        let res1 = router.handle(shift4Event, currentTab: .player, isModalActive: false, onEscape: { false })
        #expect(res1 == nil)
        #expect(ingestTabCalled == true)
        
        // 2. Cmd + Shift + Left Arrow (keyCode 123) in Player tab -> left sleeve
        let cmdShiftLeftEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 123
        )!
        let res2 = router.handle(cmdShiftLeftEvent, currentTab: .player, isModalActive: false, onEscape: { false })
        #expect(res2 == nil)
        #expect(leftSleeveCalled == true)
        
        // 3. Cmd + Shift + Left Arrow in Specs tab -> left sleeve
        leftSleeveCalled = false
        let res3 = router.handle(cmdShiftLeftEvent, currentTab: .specs, isModalActive: false, onEscape: { false })
        #expect(res3 == nil)
        #expect(leftSleeveCalled == true)
        
        // 4. Cmd + Shift + Left Arrow in Line Finder tab -> not active
        leftSleeveCalled = false
        let res4 = router.handle(cmdShiftLeftEvent, currentTab: .lineFinder, isModalActive: false, onEscape: { false })
        #expect(res4 != nil)
        #expect(leftSleeveCalled == false)
        
        // 5. Cmd + Shift + Right Arrow (keyCode 124) in Player tab -> right sleeve
        let cmdShiftRightEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        )!
        let res5 = router.handle(cmdShiftRightEvent, currentTab: .player, isModalActive: false, onEscape: { false })
        #expect(res5 == nil)
        #expect(rightSleeveCalled == true)
        
        // 6. Cmd + Shift + Right Arrow in Specs tab -> not active
        rightSleeveCalled = false
        let res6 = router.handle(cmdShiftRightEvent, currentTab: .specs, isModalActive: false, onEscape: { false })
        #expect(res6 != nil)
        #expect(rightSleeveCalled == false)
        
        // 7. Cmd + I (keyCode 34) in Player and Specs tabs -> properties
        let cmdIEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "i",
            charactersIgnoringModifiers: "i",
            isARepeat: false,
            keyCode: 34
        )!
        let res7 = router.handle(cmdIEvent, currentTab: .player, isModalActive: false, onEscape: { false })
        #expect(res7 == nil)
        #expect(propertiesCalled == true)
        
        propertiesCalled = false
        let res8 = router.handle(cmdIEvent, currentTab: .specs, isModalActive: false, onEscape: { false })
        #expect(res8 == nil)
        #expect(propertiesCalled == true)
    }
    
    @Test @MainActor
    func rightSleeveRevealNotesTabWhenNotesPresent() {
        let engine = PlayerEngine()
        
        // When activeNotes is empty:
        #expect(engine.activeNotes.isEmpty == true)
        var targetDrawerTab: PlayerDrawerTab = (!engine.activeNotes.isEmpty) ? .notes : .mediaInfo
        #expect(targetDrawerTab == .mediaInfo)
        
        // When file has active notes:
        let testNote = QCFileNote(
            frameIndex: 12,
            timecode: "00:00:00:12",
            author: "Tester",
            text: "Glitch on frame 12",
            colorTag: "red",
            createdAt: Date(),
            isResolved: false
        )
        engine.activeNotes = [testNote]
        #expect(engine.activeNotes.isEmpty == false)
        
        targetDrawerTab = (!engine.activeNotes.isEmpty) ? .notes : .mediaInfo
        #expect(targetDrawerTab == .notes)
    }
}

