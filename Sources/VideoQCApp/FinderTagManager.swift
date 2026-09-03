import SwiftUI
import Foundation

// MARK: - Native macOS Finder Tag Colors (Exact System Palette)

public enum FinderTagColor: String, CaseIterable, Identifiable, Sendable {
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case gray = "Gray"
    
    public var id: String { rawValue }
    
    public var labelNumber: Int {
        switch self {
        case .gray: return 1
        case .green: return 2
        case .purple: return 3
        case .blue: return 4
        case .yellow: return 5
        case .red: return 6
        case .orange: return 7
        }
    }
    
    public static func fromLabelNumber(_ num: Int) -> FinderTagColor? {
        switch num {
        case 1: return .gray
        case 2: return .green
        case 3: return .purple
        case 4: return .blue
        case 5: return .yellow
        case 6: return .red
        case 7: return .orange
        default: return nil
        }
    }
    
    /// Exact native macOS Finder tag dot colors matching Apple's palette
    public var color: Color {
        switch self {
        case .red:
            return Color(red: 255/255, green: 104/255, blue: 106/255)
        case .orange:
            return Color(red: 255/255, green: 169/255, blue: 89/255)
        case .yellow:
            return Color(red: 255/255, green: 222/255, blue: 40/255)
        case .green:
            return Color(red: 89/255, green: 218/255, blue: 122/255)
        case .blue:
            return Color(red: 40/255, green: 167/255, blue: 255/255)
        case .purple:
            return Color(red: 227/255, green: 93/255, blue: 244/255)
        case .gray:
            return Color(red: 173/255, green: 173/255, blue: 177/255)
        }
    }
}

// MARK: - Finder Tag Manager

public struct FinderTagManager: Sendable {
    
    /// Reads the primary macOS Finder tag for a file URL
    public static func getTag(for url: URL) -> FinderTagColor? {
        let nsURL = url as NSURL
        var val: AnyObject?
        try? nsURL.getResourceValue(&val, forKey: .tagNamesKey)
        if let names = val as? [String], let first = names.first {
            let clean = first.components(separatedBy: "\n").first ?? first
            if let matched = FinderTagColor(rawValue: clean) {
                return matched
            }
        }
        
        // Fallback to legacy labelNumber
        let res = try? url.resourceValues(forKeys: [.labelNumberKey])
        if let num = res?.labelNumber, num > 0 {
            return FinderTagColor.fromLabelNumber(num)
        }
        
        return nil
    }
    
    /// Applies or removes the Finder tag on disk and updates Finder UI
    public static func setTag(_ tag: FinderTagColor?, for url: URL) {
        let nsURL = url as NSURL
        if let tag = tag {
            let tagString = "\(tag.rawValue)\n\(tag.labelNumber)"
            try? nsURL.setResourceValue([tagString] as NSArray, forKey: .tagNamesKey)
            var mut = url
            var res = URLResourceValues()
            res.labelNumber = tag.labelNumber
            try? mut.setResourceValues(res)
        } else {
            try? nsURL.setResourceValue([] as NSArray, forKey: .tagNamesKey)
            var mut = url
            var res = URLResourceValues()
            res.labelNumber = 0
            try? mut.setResourceValues(res)
        }
    }
}
