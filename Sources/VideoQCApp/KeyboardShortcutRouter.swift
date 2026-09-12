import AppKit
import SwiftUI
import VideoQCLib

// MARK: - Shortcut Trigger

struct ShortcutTrigger: Sendable {
    let keyCodes: [UInt16]
    let characters: [String]
    let modifiers: NSEvent.ModifierFlags
    let allowShift: Bool
    
    init(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        allowShift: Bool = false
    ) {
        self.keyCodes = [keyCode]
        self.characters = []
        self.modifiers = modifiers.intersection([.command, .shift, .control, .option])
        self.allowShift = allowShift
    }
    
    init(
        character: String,
        modifiers: NSEvent.ModifierFlags = [],
        allowShift: Bool = false
    ) {
        self.keyCodes = []
        self.characters = [character.lowercased()]
        self.modifiers = modifiers.intersection([.command, .shift, .control, .option])
        self.allowShift = allowShift
    }
    
    init(
        keyCodes: [UInt16] = [],
        characters: [String] = [],
        modifiers: NSEvent.ModifierFlags = [],
        allowShift: Bool = false
    ) {
        self.keyCodes = keyCodes
        self.characters = characters.map { $0.lowercased() }
        self.modifiers = modifiers.intersection([.command, .shift, .control, .option])
        self.allowShift = allowShift
    }
    
    func matches(event: NSEvent) -> Bool {
        let eventMods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if allowShift {
            if eventMods.subtracting(.shift) != modifiers.subtracting(.shift) {
                return false
            }
        } else {
            if eventMods != modifiers {
                return false
            }
        }
        
        if keyCodes.contains(event.keyCode) {
            return true
        }
        
        if !characters.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if characters.contains(chars) {
                return true
            }
        }
        
        if !characters.isEmpty, let rawChars = event.characters?.lowercased() {
            if characters.contains(rawChars) {
                return true
            }
        }
        
        return false
    }
}

// MARK: - Shortcut Scope & Rule

@MainActor
final class KeyboardShortcutRouter {
    enum Scope: Sendable {
        case preModalGlobal
        case global
        case playerOrSpecs
        case playerOnly
    }
    
    struct Rule {
        let id: String
        let trigger: ShortcutTrigger
        let scope: Scope
        let action: () -> Bool
        
        init(
            id: String,
            trigger: ShortcutTrigger,
            scope: Scope = .global,
            action: @escaping () -> Bool
        ) {
            self.id = id
            self.trigger = trigger
            self.scope = scope
            self.action = action
        }
    }
    
    private let rules: [Rule]
    
    init(rules: [Rule]) {
        self.rules = rules
    }
    
    // MARK: - Dispatch Pipeline
    
    func handle(
        _ event: NSEvent,
        currentTab: AppTab,
        isModalActive: Bool,
        onEscape: () -> Bool
    ) -> NSEvent? {
        // 1. Text Field Responder Check (ESC or Return unfocuses)
        if let window = NSApp.keyWindow,
           let firstResponder = window.firstResponder,
           firstResponder is NSTextView {
            if event.keyCode == 53 || event.keyCode == 36 { // ESC or Return
                window.makeFirstResponder(nil)
                return nil
            }
            return event
        }
        
        // 2. Pre-Modal Global Shortcuts (e.g. Button Zoom)
        for rule in rules where rule.scope == .preModalGlobal {
            if rule.trigger.matches(event: event) {
                if rule.action() {
                    return nil
                }
            }
        }
        
        // 3. ESC Modal / Fullscreen Dismissal
        if event.keyCode == 53 {
            if onEscape() {
                return nil
            }
        }
        
        // 4. Modal Active Blocker (swallows background shortcuts when a modal dialog is shown)
        if isModalActive {
            return event
        }
        
        // 5. Scoped Dispatch
        for rule in rules where rule.scope != .preModalGlobal {
            let isScopeActive: Bool
            switch rule.scope {
            case .preModalGlobal:
                isScopeActive = false
            case .global:
                isScopeActive = true
            case .playerOrSpecs:
                isScopeActive = (currentTab == .player || currentTab == .specs)
            case .playerOnly:
                isScopeActive = (currentTab == .player)
            }
            
            guard isScopeActive else { continue }
            
            if rule.trigger.matches(event: event) {
                if rule.action() {
                    return nil
                }
            }
        }
        
        return event
    }
    
    // MARK: - Click-Away Responder Helper
    
    static func dismissTextFieldFocusIfClickedOutside(event: NSEvent) -> NSEvent {
        if let window = NSApp.keyWindow,
           let firstResponder = window.firstResponder,
           firstResponder is NSTextView {
            let clickLoc = event.locationInWindow
            if let hitView = window.contentView?.hitTest(clickLoc) {
                var isTextInput = false
                var curr: NSView? = hitView
                while let v = curr {
                    if v is NSTextField || v is NSTextView {
                        isTextInput = true
                        break
                    }
                    curr = v.superview
                }
                if !isTextInput {
                    window.makeFirstResponder(nil)
                }
            }
        }
        return event
    }
}

// MARK: - Standard Actions Contract

@MainActor
struct KeyboardShortcutActions {
    // Zoom
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void
    
    // Tabs
    var onSelectPlayerTab: () -> Void
    var onSelectSpecsTab: () -> Void
    var onSelectLineFinderTab: () -> Void
    
    // Theme
    var onToggleLightMode: () -> Void
    var onCycleAccentTheme: () -> Void
    
    // Finder Tags
    var onToggleFinderTag: (FinderTagColor) -> Bool
    var onClearFinderTag: () -> Bool
    
    // Player - Transport
    var onPressJ: () -> Void
    var onPressSlowJ: () -> Void
    var onPressK: () -> Void
    var onPressL: () -> Void
    var onPressSlowL: () -> Void
    var onToggleLooping: () -> Void
    var onToggleAutoplay: () -> Void
    var onTogglePlayPause: () -> Void
    
    // Player - Navigation
    var onStepFrame: (Bool) -> Void // forward
    var onStepFrames: (Int, Bool) -> Void // count, forward
    var onJumpToBeginning: () -> Void
    var onJumpToEnd: () -> Void
    var onSelectPreviousFile: (SlotTarget) -> Void
    var onSelectNextFile: (SlotTarget) -> Void
    
    // Player - Fullscreen & Features
    var onToggleFullscreenVideo: () -> Bool
    var onToggleFullscreenReview: () -> Bool
    var onOpenAddNote: () -> Bool
    var onJumpToNextNote: () -> Void
    var onJumpToPreviousNote: () -> Void
    var onJumpToNextFinding: () -> Void
    var onJumpToPreviousFinding: () -> Void
    var onSwapSlots: () -> Bool
    var onCycleCompareMode: () -> Bool
    var onToggleBlinkCompare: () -> Bool
    var onToggleUserGuide: () -> Void
    var onCycleClipInfo: () -> Void
    var onToggleProperties: () -> Void
    
    init(
        onZoomIn: @escaping () -> Void,
        onZoomOut: @escaping () -> Void,
        onSelectPlayerTab: @escaping () -> Void,
        onSelectSpecsTab: @escaping () -> Void,
        onSelectLineFinderTab: @escaping () -> Void,
        onToggleLightMode: @escaping () -> Void,
        onCycleAccentTheme: @escaping () -> Void,
        onToggleFinderTag: @escaping (FinderTagColor) -> Bool,
        onClearFinderTag: @escaping () -> Bool,
        onPressJ: @escaping () -> Void,
        onPressSlowJ: @escaping () -> Void,
        onPressK: @escaping () -> Void,
        onPressL: @escaping () -> Void,
        onPressSlowL: @escaping () -> Void,
        onToggleLooping: @escaping () -> Void,
        onToggleAutoplay: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onStepFrame: @escaping (Bool) -> Void,
        onStepFrames: @escaping (Int, Bool) -> Void,
        onJumpToBeginning: @escaping () -> Void,
        onJumpToEnd: @escaping () -> Void,
        onSelectPreviousFile: @escaping (SlotTarget) -> Void,
        onSelectNextFile: @escaping (SlotTarget) -> Void,
        onToggleFullscreenVideo: @escaping () -> Bool,
        onToggleFullscreenReview: @escaping () -> Bool,
        onOpenAddNote: @escaping () -> Bool,
        onJumpToNextNote: @escaping () -> Void,
        onJumpToPreviousNote: @escaping () -> Void,
        onJumpToNextFinding: @escaping () -> Void,
        onJumpToPreviousFinding: @escaping () -> Void,
        onSwapSlots: @escaping () -> Bool,
        onCycleCompareMode: @escaping () -> Bool,
        onToggleBlinkCompare: @escaping () -> Bool,
        onToggleUserGuide: @escaping () -> Void,
        onCycleClipInfo: @escaping () -> Void,
        onToggleProperties: @escaping () -> Void
    ) {
        self.onZoomIn = onZoomIn
        self.onZoomOut = onZoomOut
        self.onSelectPlayerTab = onSelectPlayerTab
        self.onSelectSpecsTab = onSelectSpecsTab
        self.onSelectLineFinderTab = onSelectLineFinderTab
        self.onToggleLightMode = onToggleLightMode
        self.onCycleAccentTheme = onCycleAccentTheme
        self.onToggleFinderTag = onToggleFinderTag
        self.onClearFinderTag = onClearFinderTag
        self.onPressJ = onPressJ
        self.onPressSlowJ = onPressSlowJ
        self.onPressK = onPressK
        self.onPressL = onPressL
        self.onPressSlowL = onPressSlowL
        self.onToggleLooping = onToggleLooping
        self.onToggleAutoplay = onToggleAutoplay
        self.onTogglePlayPause = onTogglePlayPause
        self.onStepFrame = onStepFrame
        self.onStepFrames = onStepFrames
        self.onJumpToBeginning = onJumpToBeginning
        self.onJumpToEnd = onJumpToEnd
        self.onSelectPreviousFile = onSelectPreviousFile
        self.onSelectNextFile = onSelectNextFile
        self.onToggleFullscreenVideo = onToggleFullscreenVideo
        self.onToggleFullscreenReview = onToggleFullscreenReview
        self.onOpenAddNote = onOpenAddNote
        self.onJumpToNextNote = onJumpToNextNote
        self.onJumpToPreviousNote = onJumpToPreviousNote
        self.onJumpToNextFinding = onJumpToNextFinding
        self.onJumpToPreviousFinding = onJumpToPreviousFinding
        self.onSwapSlots = onSwapSlots
        self.onCycleCompareMode = onCycleCompareMode
        self.onToggleBlinkCompare = onToggleBlinkCompare
        self.onToggleUserGuide = onToggleUserGuide
        self.onCycleClipInfo = onCycleClipInfo
        self.onToggleProperties = onToggleProperties
    }
}

// MARK: - Factory & Declarative Registry

extension KeyboardShortcutRouter {
    static func standardRouter(actions: KeyboardShortcutActions) -> KeyboardShortcutRouter {
        let rules: [Rule] = [
            // Pre-Modal Global (Zoom)
            Rule(
                id: "zoomIn",
                trigger: ShortcutTrigger(keyCodes: [24, 69], characters: ["=", "+"], modifiers: [.command], allowShift: true),
                scope: .preModalGlobal
            ) {
                actions.onZoomIn()
                return true
            },
            Rule(
                id: "zoomOut",
                trigger: ShortcutTrigger(keyCodes: [27, 78], characters: ["-", "_"], modifiers: [.command], allowShift: true),
                scope: .preModalGlobal
            ) {
                actions.onZoomOut()
                return true
            },
            
            // Global: Tab Switching
            Rule(
                id: "tabPlayer",
                trigger: ShortcutTrigger(keyCodes: [18], characters: ["1", "!"], modifiers: [.shift]),
                scope: .global
            ) {
                actions.onSelectPlayerTab()
                return true
            },
            Rule(
                id: "tabSpecs",
                trigger: ShortcutTrigger(keyCodes: [19], characters: ["2", "@"], modifiers: [.shift]),
                scope: .global
            ) {
                actions.onSelectSpecsTab()
                return true
            },
            Rule(
                id: "tabLineFinder",
                trigger: ShortcutTrigger(keyCodes: [20], characters: ["3", "#"], modifiers: [.shift]),
                scope: .global
            ) {
                actions.onSelectLineFinderTab()
                return true
            },
            
            // Global: Themes
            Rule(
                id: "cycleAccentTheme",
                trigger: ShortcutTrigger(keyCodes: [17], characters: ["t"], modifiers: [.shift]),
                scope: .global
            ) {
                actions.onCycleAccentTheme()
                return true
            },
            Rule(
                id: "toggleLightDark",
                trigger: ShortcutTrigger(keyCodes: [17], characters: ["t"], modifiers: []),
                scope: .global
            ) {
                actions.onToggleLightMode()
                return true
            },
            
            // Finder Tags (Player & Specs Tabs)
            Rule(
                id: "tagRed",
                trigger: ShortcutTrigger(keyCodes: [18], characters: ["1"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onToggleFinderTag(.red)
            },
            Rule(
                id: "tagGreen",
                trigger: ShortcutTrigger(keyCodes: [19], characters: ["2"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onToggleFinderTag(.green)
            },
            Rule(
                id: "tagBlue",
                trigger: ShortcutTrigger(keyCodes: [20], characters: ["3"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onToggleFinderTag(.blue)
            },
            Rule(
                id: "tagYellow",
                trigger: ShortcutTrigger(keyCodes: [21], characters: ["4"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onToggleFinderTag(.yellow)
            },
            Rule(
                id: "tagOrange",
                trigger: ShortcutTrigger(keyCodes: [23], characters: ["5"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onToggleFinderTag(.orange)
            },
            Rule(
                id: "tagPurple",
                trigger: ShortcutTrigger(keyCodes: [22], characters: ["6"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onToggleFinderTag(.purple)
            },
            Rule(
                id: "tagGray",
                trigger: ShortcutTrigger(keyCodes: [26], characters: ["7"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onToggleFinderTag(.gray)
            },
            Rule(
                id: "tagClear",
                trigger: ShortcutTrigger(keyCodes: [29], characters: ["0"], modifiers: []),
                scope: .playerOrSpecs
            ) {
                actions.onClearFinderTag()
            },
            
            // Player: Shuttle & Playback
            Rule(
                id: "shuttleSlowJ",
                trigger: ShortcutTrigger(characters: ["j"], modifiers: [.shift]),
                scope: .playerOnly
            ) {
                actions.onPressSlowJ()
                return true
            },
            Rule(
                id: "shuttleJ",
                trigger: ShortcutTrigger(characters: ["j"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onPressJ()
                return true
            },
            Rule(
                id: "shuttleK",
                trigger: ShortcutTrigger(characters: ["k"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onPressK()
                return true
            },
            Rule(
                id: "shuttleSlowL",
                trigger: ShortcutTrigger(characters: ["l"], modifiers: [.shift]),
                scope: .playerOnly
            ) {
                actions.onPressSlowL()
                return true
            },
            Rule(
                id: "shuttleLoop",
                trigger: ShortcutTrigger(characters: ["l"], modifiers: [.command]),
                scope: .playerOnly
            ) {
                actions.onToggleLooping()
                return true
            },
            Rule(
                id: "shuttleL",
                trigger: ShortcutTrigger(characters: ["l"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onPressL()
                return true
            },
            Rule(
                id: "autoplayToggle",
                trigger: ShortcutTrigger(characters: ["a"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onToggleAutoplay()
                return true
            },
            Rule(
                id: "playPause",
                trigger: ShortcutTrigger(keyCodes: [49], characters: [" "], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onTogglePlayPause()
                return true
            },
            
            // Player: Fullscreen
            Rule(
                id: "fullscreenReview",
                trigger: ShortcutTrigger(characters: ["f"], modifiers: [.shift]),
                scope: .playerOnly
            ) {
                actions.onToggleFullscreenReview()
            },
            Rule(
                id: "fullscreenVideo",
                trigger: ShortcutTrigger(characters: ["f"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onToggleFullscreenVideo()
            },
            
            // Player: Review Notes
            Rule(
                id: "addNote",
                trigger: ShortcutTrigger(characters: ["n"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onOpenAddNote()
            },
            Rule(
                id: "nextNoteBracket",
                trigger: ShortcutTrigger(keyCodes: [30], characters: ["]"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onJumpToNextNote()
                return true
            },
            Rule(
                id: "nextNoteOptionN",
                trigger: ShortcutTrigger(characters: ["n"], modifiers: [.option]),
                scope: .playerOnly
            ) {
                actions.onJumpToNextNote()
                return true
            },
            Rule(
                id: "prevNoteBracket",
                trigger: ShortcutTrigger(keyCodes: [33], characters: ["["], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onJumpToPreviousNote()
                return true
            },
            Rule(
                id: "prevNoteOptionShiftN",
                trigger: ShortcutTrigger(characters: ["n"], modifiers: [.option, .shift]),
                scope: .playerOnly
            ) {
                actions.onJumpToPreviousNote()
                return true
            },
            
            // Player: Line Glitch Findings
            Rule(
                id: "prevFinding",
                trigger: ShortcutTrigger(characters: ["m"], modifiers: [.shift]),
                scope: .playerOnly
            ) {
                actions.onJumpToPreviousFinding()
                return true
            },
            Rule(
                id: "nextFinding",
                trigger: ShortcutTrigger(characters: ["m"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onJumpToNextFinding()
                return true
            },
            
            // Player: Compare Modes & Slots
            Rule(
                id: "swapSlots",
                trigger: ShortcutTrigger(characters: ["s", "x"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onSwapSlots()
            },
            Rule(
                id: "cycleCompare",
                trigger: ShortcutTrigger(characters: ["c"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onCycleCompareMode()
            },
            Rule(
                id: "blinkCompare",
                trigger: ShortcutTrigger(keyCodes: [48], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onToggleBlinkCompare()
            },
            
            // Player: Help & Clip Info
            Rule(
                id: "userGuideQuestion",
                trigger: ShortcutTrigger(characters: ["?"], modifiers: [], allowShift: true),
                scope: .playerOnly
            ) {
                actions.onToggleUserGuide()
                return true
            },
            Rule(
                id: "userGuideCmdSlash",
                trigger: ShortcutTrigger(characters: ["/"], modifiers: [.command]),
                scope: .playerOnly
            ) {
                actions.onToggleUserGuide()
                return true
            },
            Rule(
                id: "clipInfo",
                trigger: ShortcutTrigger(characters: ["i"], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onCycleClipInfo()
                return true
            },
            
            // Player: Media Info / Properties
            Rule(
                id: "propertiesCmdI",
                trigger: ShortcutTrigger(characters: ["i"], modifiers: [.command]),
                scope: .playerOnly
            ) {
                actions.onToggleProperties()
                return true
            },
            Rule(
                id: "propertiesCtrlI",
                trigger: ShortcutTrigger(characters: ["i"], modifiers: [.control]),
                scope: .playerOnly
            ) {
                actions.onToggleProperties()
                return true
            },
            Rule(
                id: "propertiesCmdP",
                trigger: ShortcutTrigger(characters: ["p"], modifiers: [.command]),
                scope: .playerOnly
            ) {
                actions.onToggleProperties()
                return true
            },
            
            // Player: Queue Navigation (Arrow Keys)
            Rule(
                id: "prevFileSlotB",
                trigger: ShortcutTrigger(keyCodes: [126], modifiers: [.option]),
                scope: .playerOnly
            ) {
                actions.onSelectPreviousFile(.slotB)
                return true
            },
            Rule(
                id: "prevFileSlotA",
                trigger: ShortcutTrigger(keyCodes: [126], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onSelectPreviousFile(.slotA)
                return true
            },
            Rule(
                id: "nextFileSlotB",
                trigger: ShortcutTrigger(keyCodes: [125], modifiers: [.option]),
                scope: .playerOnly
            ) {
                actions.onSelectNextFile(.slotB)
                return true
            },
            Rule(
                id: "nextFileSlotA",
                trigger: ShortcutTrigger(keyCodes: [125], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onSelectNextFile(.slotA)
                return true
            },
            
            // Player: Frame Stepping (Arrow Keys)
            Rule(
                id: "stepBack5",
                trigger: ShortcutTrigger(keyCodes: [123], modifiers: [.shift]),
                scope: .playerOnly
            ) {
                actions.onStepFrames(5, false)
                return true
            },
            Rule(
                id: "stepBack1",
                trigger: ShortcutTrigger(keyCodes: [123], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onStepFrame(false)
                return true
            },
            Rule(
                id: "stepForward5",
                trigger: ShortcutTrigger(keyCodes: [124], modifiers: [.shift]),
                scope: .playerOnly
            ) {
                actions.onStepFrames(5, true)
                return true
            },
            Rule(
                id: "stepForward1",
                trigger: ShortcutTrigger(keyCodes: [124], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onStepFrame(true)
                return true
            },
            
            // Player: Home / End / Shift+I (Jump to Start)
            Rule(
                id: "jumpBeginningHome",
                trigger: ShortcutTrigger(keyCodes: [115], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onJumpToBeginning()
                return true
            },
            Rule(
                id: "jumpBeginningShiftI",
                trigger: ShortcutTrigger(keyCodes: [34], characters: ["i"], modifiers: [.shift]),
                scope: .playerOnly
            ) {
                actions.onJumpToBeginning()
                return true
            },
            Rule(
                id: "jumpEnd",
                trigger: ShortcutTrigger(keyCodes: [119], modifiers: []),
                scope: .playerOnly
            ) {
                actions.onJumpToEnd()
                return true
            }
        ]
        
        return KeyboardShortcutRouter(rules: rules)
    }
}
