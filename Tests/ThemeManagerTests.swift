import Foundation
import SwiftUI
import Testing
@testable import QCpie
@testable import VideoQCLib

@Suite("ThemeManager Custom Accents & Presets Tests")
struct ThemeManagerTests {
    
    @Test @MainActor
    func factoryPresetsAndLimits() {
        let manager = ThemeManager.shared
        manager.resetToDefault()
        
        #expect(ThemeManager.maxTotalPresets == 10)
        #expect(StudioThemeConfig.presets.count == 2)
        #expect(manager.currentTheme.id == StudioThemeConfig.muted.id)
        #expect(manager.canSaveMorePresets == true)
    }
    
    @Test @MainActor
    func updateColorDetachesToCustom() {
        let manager = ThemeManager.shared
        manager.applyTheme(StudioThemeConfig.muted)
        #expect(manager.currentTheme.isPreset == true)
        
        // Update slot A green to bright neon green
        manager.updateAccentColor(slot: .green, hex: "#00FF88")
        
        #expect(manager.currentTheme.greenHex == "#00FF88")
        #expect(manager.currentTheme.name == "Custom")
        #expect(manager.currentTheme.isPreset == false)
        
        // Update slot B purple to cyan
        manager.updateAccentColor(slot: .purple, hex: "#00FFFF")
        #expect(manager.currentTheme.purpleHex == "#00FFFF")
    }
    
    @Test @MainActor
    func saveAndLimitPresetsToTenTotal() {
        let manager = ThemeManager.shared
        // Clear existing user presets for test
        for preset in manager.userPresets {
            manager.deletePreset(id: preset.id)
        }
        
        #expect(manager.allThemes.count == 2)
        
        // Save presets up to the limit of 10 total
        for i in 1...8 {
            let saved = manager.savePreset(name: "Test Theme \(i)")
            #expect(saved == true)
        }
        
        #expect(manager.allThemes.count == 10)
        #expect(manager.canSaveMorePresets == false)
        
        // 11th preset must be rejected
        let rejected = manager.savePreset(name: "Overflow Preset")
        #expect(rejected == false)
        #expect(manager.allThemes.count == 10)
        
        // Clean up test presets
        for preset in manager.userPresets {
            manager.deletePreset(id: preset.id)
        }
        #expect(manager.allThemes.count == 2)
    }
    
    @Test @MainActor
    func deletePresetFallsBackToDefaultWhenActive() {
        let manager = ThemeManager.shared
        manager.applyTheme(StudioThemeConfig.vivid)
        manager.updateAccentColor(slot: .blue, hex: "#112233")
        
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
        manager.applyTheme(StudioThemeConfig.vivid)
        
        manager.cycleAccentTheme()
        #expect(manager.currentTheme.name == "Custom Cycle Preset")
        
        // Clean up
        for preset in manager.userPresets {
            manager.deletePreset(id: preset.id)
        }
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
}

