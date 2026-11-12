import Foundation
import VideoQCLib

/// What Inspect's checks found in a file (Check Subs & Graphics, Check Loudness), for comparing with its plan row.
/// Nil parts weren't checked: nothing is flagged before a check has run.
struct PlanContent: Equatable, Sendable {
    struct Picture: Equatable, Sendable {
        var subtitles: Bool
        /// Lines seen in the subtitle area, subtitles or not (one line in a short clip).
        var lowerLines: Int
        var language: String?
        /// Text graphics left after Not a Graphic (text, start, end in seconds).
        var graphics: [PictureTextCheck.Sighting]
    }

    var duration: Double
    var picture: Picture?
    /// nil: Check Loudness hasn't run (or the file has no audio track: that's a spec problem already).
    var silent: Bool?
    var loudness: Double?

    init?(_ asset: DeliverableAsset) {
        duration = asset.durationSeconds
        if let check = asset.pictureText, !check.isUnreadable, !check.isUnavailable {
            picture = Picture(subtitles: check.subtitlesLikely, lowerLines: check.lowerLineCount,
                              language: check.subtitleLanguage, graphics: check.graphics)
        }
        if asset.hasAudio, let measured = asset.loudness {
            silent = measured.isSilent
            loudness = measured.integrated
        }
        if picture == nil, silent == nil { return nil }
    }

    init(duration: Double, picture: Picture? = nil, silent: Bool? = nil, loudness: Double? = nil) {
        self.duration = duration; self.picture = picture; self.silent = silent; self.loudness = loudness
    }
}

/// One way a file's picture or sound differs from its row: the cell it belongs to in Inspect, and why.
struct PlanContentFlag: Equatable, Sendable, Hashable {
    enum Area: Sendable, Hashable { case graphics, subtitles, sound }
    let area: Area
    let text: String
}

/// The row's Logos / Graphics / CTA, Subs and Sound columns against what the checks found. Only clear answers are
/// compared ("tbc", empty or unknown wording says nothing), so a flag means the row and the file disagree.
enum PlanContentCheck {
    static func flags(_ row: PlanRow, _ content: PlanContent) -> [PlanContentFlag] {
        var flags: [PlanContentFlag] = []
        if let picture = content.picture {
            flags += logoFlags(row, picture, duration: content.duration)
            flags += subtitleFlags(row, picture)
        }
        if let silent = content.silent {
            let sound = row.value(.sound)
            if silent, PlanMatcher.wantsSound(row) {
                flags.append(.init(area: .sound, text: "The plan asks for sound (Sound: \(sound)), but the audio is silent."))
            } else if !silent, isNo(sound) {
                let level = content.loudness.map { String(format: " (%.1f LUFS)", $0) } ?? ""
                flags.append(.init(area: .sound, text: "The plan says no sound (Sound: \(sound)), but the audio isn't silent\(level)."))
            }
        }
        return flags
    }

    private static func logoFlags(_ row: PlanRow, _ picture: PlanContent.Picture, duration: Double) -> [PlanContentFlag] {
        let logos = row.value(.logos)
        let wording = logos.lowercased()
        let wantsLogo = !isNo(logos) && !wording.hasPrefix("no") && !wording.hasPrefix("without")
            && (wording.hasPrefix("yes") || wording.contains("logo") || wording.contains("intro") || wording.contains("outro"))
        let shown = "Logos: \(logos.replacingOccurrences(of: "\n", with: " "))"
        if wantsLogo {
            guard let first = picture.graphics.first else {
                return [.init(area: .graphics, text: "The plan asks for a logo (\(shown)), but no text on screen was found. Logos without letters aren't seen.")]
            }
            // When: "first 2s", or an intro and outro logo.
            var missing: [String] = []
            if let seconds = firstSeconds(wording), first.start > seconds + 0.5 {
                missing.append("in the first \(format(seconds)) s (the first text appears at \(format(first.start)) s)")
            }
            if wording.contains("intro"), first.start > 2.5 { missing.append("at the start") }
            if wording.contains("outro"), duration > 0, !picture.graphics.contains(where: { $0.end >= duration - 2.5 }) {
                missing.append("at the end")
            }
            if !missing.isEmpty {
                return [.init(area: .graphics, text: "The plan asks for a logo \(missing.joined(separator: " and ")) (\(shown)), but no text on screen was found there.")]
            }
        } else if isNo(logos), isNo(row.value(.graphics)), !wantsYes(row.value(.cta)), let first = picture.graphics.first {
            // Only when the row rules out graphics too: titles and supers are text on screen as well.
            return [.init(area: .graphics, text: "The plan has no logo or graphics (\(shown), Graphics: \(row.value(.graphics))), but text is on screen: “\(first.text)” at \(format(first.start)) s.")]
        }
        return []
    }

    private static func subtitleFlags(_ row: PlanRow, _ picture: PlanContent.Picture) -> [PlanContentFlag] {
        let subs = row.value(.subs)
        let shown = "Subs: \(subs)"
        if wantsYes(subs) {
            if !picture.subtitles {
                guard picture.lowerLines == 0 else { return [] }   // one line read: too little to say either way
                return [.init(area: .subtitles, text: "The plan asks for subtitles (\(shown)), but none were found.")]
            }
            if let wanted = language(in: subs), let read = picture.language, !wanted.codes.contains(where: { read.hasPrefix($0) }) {
                let readName = Locale(identifier: "en").localizedString(forLanguageCode: read) ?? read
                return [.init(area: .subtitles, text: "The plan asks for \(wanted.name) subtitles (\(shown)), but they read as \(readName).")]
            }
        } else if isNo(subs), picture.subtitles {
            return [.init(area: .subtitles, text: "The plan says no subtitles (\(shown)), but subtitles were found.")]
        }
        return []
    }

    // MARK: - Wording

    static func wantsYes(_ value: String) -> Bool {
        let t = value.lowercased().trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("yes") || t == "y"
    }

    /// A plain no. Only whole answers: "No VO" or "No music" still has sound, so it says nothing.
    static func isNo(_ value: String) -> Bool {
        let t = value.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return ["no", "n", "none", "clean", "silent", "mute", "no sound", "no audio", "no logo", "no logos",
                "no graphics", "no subs", "no subtitles"].contains(t)
    }

    /// "Yes - first 2s" → 2 (a number right after "first", then s / sec / seconds). No regex: this runs for every
    /// checked file on each plan update.
    static func firstSeconds(_ wording: String) -> Double? {
        guard let first = wording.range(of: "first") else { return nil }
        let rest = wording[first.upperBound...].drop { $0 == " " }
        let number = rest.prefix { $0.isNumber || $0 == "." }
        let unit = rest.dropFirst(number.count).drop { $0 == " " }.prefix { $0.isLetter }
        guard let seconds = Double(number), ["s", "sec", "secs", "second", "seconds"].contains(String(unit)) else { return nil }
        return seconds
    }

    /// Languages a Subs value names ("Yes - ENG", "Yes EN", "Yes French"), as `NLLanguage` code prefixes.
    private static let languages: [(words: Set<String>, name: String, codes: [String])] = [
        (["en", "eng", "english"], "English", ["en"]), (["fr", "fra", "fre", "french"], "French", ["fr"]),
        (["de", "ger", "deu", "german"], "German", ["de"]), (["es", "spa", "esp", "spanish"], "Spanish", ["es"]),
        (["it", "ita", "italian"], "Italian", ["it"]), (["pt", "por", "portuguese"], "Portuguese", ["pt"]),
        (["nl", "dut", "nld", "dutch"], "Dutch", ["nl"]), (["ja", "jp", "jpn", "japanese"], "Japanese", ["ja"]),
        (["zh", "cn", "chi", "zho", "chinese"], "Chinese", ["zh"]), (["ko", "kr", "kor", "korean"], "Korean", ["ko"]),
        (["ar", "ara", "arabic"], "Arabic", ["ar"]), (["ru", "rus", "russian"], "Russian", ["ru"]),
        (["pl", "pol", "polish"], "Polish", ["pl"]), (["sv", "swe", "swedish"], "Swedish", ["sv"]),
        (["da", "dan", "danish"], "Danish", ["da"]), (["fi", "fin", "finnish"], "Finnish", ["fi"]),
        (["tr", "tur", "turkish"], "Turkish", ["tr"]),
    ]

    /// The one language a Subs value names (nil for none or several: "Yes EN/FR" can't be checked as one).
    static func language(in subs: String) -> (name: String, codes: [String])? {
        let words = subs.lowercased().split { !$0.isLetter }.map(String.init)
        let named = languages.filter { !$0.words.isDisjoint(with: words) }
        guard named.count == 1 else { return nil }
        return (named[0].name, named[0].codes)
    }

    private static func format(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}
