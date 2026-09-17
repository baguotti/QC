import Foundation
import AppKit
import SwiftUI

// MARK: - Detected Note Link Representation

public enum DetectedNoteLink: Identifiable, Equatable {
    case webURL(url: URL, displayString: String)
    case filePath(path: String, displayString: String)
    
    public var id: String {
        switch self {
        case .webURL(let url, _): return "web:\(url.absoluteString)"
        case .filePath(let path, _): return "file:\(path)"
        }
    }
    
    public var displayString: String {
        switch self {
        case .webURL(_, let str): return str
        case .filePath(_, let str): return str
        }
    }
    
    public var isWeb: Bool {
        if case .webURL = self { return true }
        return false
    }
    
    public var iconName: String {
        switch self {
        case .webURL: return "arrow.up.right.square"
        case .filePath: return "folder.fill"
        }
    }
    
    public var label: String {
        switch self {
        case .webURL(let url, let str):
            let host = url.host ?? str
            let clean = host.replacingOccurrences(of: "www.", with: "")
            return clean.isEmpty ? "Open Link" : clean
        case .filePath(let path, _):
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? "Reveal in Finder" : name
        }
    }
    
    public func open() {
        switch self {
        case .webURL(let url, _):
            NSWorkspace.shared.open(url)
        case .filePath(let path, _):
            Self.revealInFinder(path: path)
        }
    }
    
    public static func revealInFinder(path: String) {
        let clean = (path as NSString).expandingTildeInPath
        let fm = FileManager.default
        if fm.fileExists(atPath: clean) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: clean, isDirectory: &isDir)
            if isDir.boolValue {
                NSWorkspace.shared.open(URL(fileURLWithPath: clean))
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clean)])
            }
        } else {
            let parent = (clean as NSString).deletingLastPathComponent
            if fm.fileExists(atPath: parent) {
                NSWorkspace.shared.open(URL(fileURLWithPath: parent))
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: clean))
            }
        }
    }
}

// MARK: - Note Link Parser & Attributed String Builder

public struct NoteLinkParser {
    
    private struct MatchItem {
        let range: NSRange
        let link: DetectedNoteLink
    }
    
    public static func detectLinksAndPaths(in text: String) -> [DetectedNoteLink] {
        findMatches(in: text).map { $0.link }
    }
    
    private static func findMatches(in text: String) -> [MatchItem] {
        guard !text.isEmpty else { return [] }
        var matches: [MatchItem] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        
        // 1. Detect Web & Data Links via NSDataDetector
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let dataMatches = detector.matches(in: text, options: [], range: fullRange)
            for m in dataMatches {
                let matchedString = nsText.substring(with: m.range)
                if let url = m.url {
                    if url.isFileURL {
                        matches.append(MatchItem(range: m.range, link: .filePath(path: url.path, displayString: matchedString)))
                    } else {
                        matches.append(MatchItem(range: m.range, link: .webURL(url: url, displayString: matchedString)))
                    }
                }
            }
        }
        
        // 2. Detect Quoted Local File Paths e.g. "/Volumes/Media/Cut 1.mov" or '~/Downloads/test.mov'
        let quotedPattern = #"[\"']((?:\/|~\/)[^\"']+)[\"']"#
        if let quotedRegex = try? NSRegularExpression(pattern: quotedPattern, options: []) {
            let quotedMatches = quotedRegex.matches(in: text, options: [], range: fullRange)
            for m in quotedMatches {
                guard m.numberOfRanges >= 2 else { continue }
                let innerRange = m.range(at: 1)
                let rawPath = nsText.substring(with: innerRange)
                if !overlaps(innerRange, with: matches) {
                    matches.append(MatchItem(range: innerRange, link: .filePath(path: rawPath, displayString: rawPath)))
                }
            }
        }
        
        // 3. Detect Unquoted Local File Paths (supports spaces, hyphens, subdirectories, and media extensions)
        // Directory segments: cannot start or end with a space before the slash delimiter
        let seg = #"[^\/\s\r\n"'\<\>](?:[^\/\r\n"'\<\>]*[^\/\s\r\n"'\<\>])?"#
        let dirSegs = #"(?:"# + seg + #"\/(?!\s))*"#
        
        // Sub-patterns:
        // b1: filename with extension (e.g. .mp4, .mov, .mkv, .wav, .jpg, etc.)
        let b1 = seg + #"\.[a-zA-Z0-9]{1,8}(?=[\s,;:!?\)\>\]\}\"']|$)"#
        // b2: directory path ending with a trailing slash
        let b2 = seg + #"\/"#
        // b3: standard path token without spaces (safe inline token)
        let b3 = #"[^\/\s\r\n"'\<\>]+(?=[\s,;:!?\)\>\]\}\"']|$)"#
        
        let inlinePattern = #"(?<=^|[\s\(\[\{\<\>])(?:\/|~\/)"# + dirSegs + #"(?:"# + b1 + #"|"# + b2 + #"|"# + b3 + #")"#
        let standaloneLinePattern = #"(?<=^|[\r\n])\s*((?:\/|~\/)(?:"# + seg + #"\/(?!\s))*"# + seg + #"\/?)\s*(?=[\r\n]|$)"#
        
        // 3a. First, check for full standalone line paths (e.g. path pasted on its own line)
        if let lineRegex = try? NSRegularExpression(pattern: standaloneLinePattern, options: []) {
            let lineMatches = lineRegex.matches(in: text, options: [], range: fullRange)
            for m in lineMatches {
                guard m.numberOfRanges >= 2 else { continue }
                var range = m.range(at: 1)
                var rawPath = nsText.substring(with: range)
                
                let punctuation = CharacterSet(charactersIn: ".,;:!?)>\"']")
                while let last = rawPath.unicodeScalars.last, punctuation.contains(last) {
                    rawPath.removeLast()
                    range.length -= 1
                }
                
                if rawPath == "/" || rawPath == "~/" || rawPath.isEmpty { continue }
                
                if !overlaps(range, with: matches) {
                    matches.append(MatchItem(range: range, link: .filePath(path: rawPath, displayString: rawPath)))
                }
            }
        }
        
        // 3b. Next, detect inline unquoted paths (with extensions, trailing slashes, or compact segments)
        if let inlineRegex = try? NSRegularExpression(pattern: inlinePattern, options: []) {
            let inlineMatches = inlineRegex.matches(in: text, options: [], range: fullRange)
            for m in inlineMatches {
                var range = m.range
                var rawPath = nsText.substring(with: range)
                
                // Trim trailing sentence punctuation
                let punctuation = CharacterSet(charactersIn: ".,;:!?)>\"']")
                while let last = rawPath.unicodeScalars.last, punctuation.contains(last) {
                    rawPath.removeLast()
                    range.length -= 1
                }
                
                // Ignore single slash or tilde slash with no target
                if rawPath == "/" || rawPath == "~/" || rawPath.isEmpty {
                    continue
                }
                
                if !overlaps(range, with: matches) {
                    matches.append(MatchItem(range: range, link: .filePath(path: rawPath, displayString: rawPath)))
                }
            }
        }
        
        // Sort in text order
        return matches.sorted { $0.range.location < $1.range.location }
    }
    
    private static func overlaps(_ range: NSRange, with items: [MatchItem]) -> Bool {
        for item in items {
            if NSIntersectionRange(range, item.range).length > 0 {
                return true
            }
        }
        return false
    }
    
    public static func buildAttributedString(
        text: String,
        isResolved: Bool,
        accentColor: Color,
        textMuted: Color,
        textMain: Color
    ) -> (attributedString: AttributedString, links: [DetectedNoteLink]) {
        let items = findMatches(in: text)
        if items.isEmpty {
            var plain = AttributedString(text)
            plain.foregroundColor = isResolved ? textMuted : textMain
            return (plain, [])
        }
        
        var result = AttributedString()
        let nsString = text as NSString
        var currentIndex = 0
        var detectedLinks: [DetectedNoteLink] = []
        
        for item in items {
            // Append preceding plain text
            if item.range.location > currentIndex {
                let plainSub = nsString.substring(with: NSRange(location: currentIndex, length: item.range.location - currentIndex))
                var plainAttr = AttributedString(plainSub)
                plainAttr.foregroundColor = isResolved ? textMuted : textMain
                result.append(plainAttr)
            }
            
            // Append link token
            let linkSub = nsString.substring(with: item.range)
            var linkAttr = AttributedString(linkSub)
            linkAttr.underlineStyle = .single
            linkAttr.foregroundColor = isResolved ? textMuted : accentColor
            
            switch item.link {
            case .webURL(let url, _):
                linkAttr.link = url
            case .filePath(let path, _):
                var comp = URLComponents()
                comp.scheme = "qcpie-reveal"
                comp.host = "open"
                comp.queryItems = [URLQueryItem(name: "path", value: path)]
                if let url = comp.url {
                    linkAttr.link = url
                }
            }
            
            result.append(linkAttr)
            if !detectedLinks.contains(item.link) {
                detectedLinks.append(item.link)
            }
            currentIndex = item.range.location + item.range.length
        }
        
        // Append trailing plain text
        if currentIndex < nsString.length {
            let remSub = nsString.substring(from: currentIndex)
            var remAttr = AttributedString(remSub)
            remAttr.foregroundColor = isResolved ? textMuted : textMain
            result.append(remAttr)
        }
        
        return (result, detectedLinks)
    }
}
