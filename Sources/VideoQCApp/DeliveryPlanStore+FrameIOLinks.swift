import Foundation
import SwiftUI
import VideoQCLib

/// Frame.io links on rows: uploads, listings, codes, and suggested links.
extension DeliveryPlanStore {
    /// The row's Frame.io link as shown (a pending edit wins); "" when none.
    func frameioLink(_ row: PlanRow) -> String { PlanGrid.normalized(shown(.frameio, row)) }

    /// Whether rows can hold Frame.io links: the QCpie tab has a Frame.io column for every code.
    var hasFrameIOColumn: Bool { hasQCTab || headers.values.contains { $0.columns[.frameio] != nil } }

    /// Codes (lower case) whose rows are in the plan, found in a file name as whole tokens ("…_KL0001.mp4").
    func codes(inFileNamed name: String) -> Set<String> {
        let tokens = PlanMatcher.tokens((name as NSString).deletingPathExtension)
        guard !tokens.isEmpty else { return [] }
        if codeIndex?.rows != rowsVersion {
            var byToken: [String: [(code: String, tokens: [String])]] = [:]
            var seen = Set<String>()
            for row in rows {
                guard let code = row.code?.lowercased(), !code.isEmpty, seen.insert(code).inserted else { continue }
                let codeTokens = PlanMatcher.tokens(code)
                if let first = codeTokens.first { byToken[first, default: []].append((code, codeTokens)) }
            }
            codeIndex = (rowsVersion, byToken)
        }
        var found = Set<String>()
        for token in Set(tokens) {
            for entry in codeIndex?.byToken[token] ?? [] where PlanMatcher.contains(tokens, entry.tokens) { found.insert(entry.code) }
        }
        return found
    }

    func rows(withCode code: String) -> [PlanRow] {
        if rowsByCode?.version != rowsVersion {
            var map: [String: [PlanRow]] = [:]
            for row in rows { if let key = row.code?.lowercased() { map[key, default: []].append(row) } }
            rowsByCode = (rowsVersion, map)
        }
        return rowsByCode?.map[code.lowercased()] ?? []
    }

    nonisolated static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "2026-11-05 10:42 UTC": the Uploaded column.
    nonisolated static func uploadStamp(_ date: Date) -> String {
        PlanUpload.stampFormatter.string(from: date) + " UTC"
    }

    /// QCpie uploaded `file` (the Upload tab) as Frame.io file `fileID`: its row's Frame.io column gets the file's link
    /// and Uploaded the date. A newer upload replaces an older link. Files whose row isn't clear (none, or several codes
    /// in the name) are left for Link Frame.io File….
    func uploaded(_ file: URL, account: String, fileID: String) async {
        guard config != nil else { return }
        // Uploading before the plan was opened this session: its rows aren't loaded yet (the cache, else one read).
        if rows.isEmpty { await loadCachedIfNeeded() }
        if rows.isEmpty { await refresh() }
        var codes = Set<String>()
        // The queue and Inspect can spell the same path differently (symlinks, /private/var…).
        let info = fileIndex[file] ?? fileIndex[file.standardizedFileURL] ?? fileIndex[file.resolvingSymlinksInPath()]
        if let code = info?.code, !code.isEmpty {
            codes = [code.lowercased()]
        } else {
            // Not one of the plan's matched files: the code alone could be another campaign's, so the name must also
            // hold the row's name (as when linking while browsing).
            let fileTokens = PlanMatcher.tokens(file.deletingPathExtension().lastPathComponent)
            codes = self.codes(inFileNamed: file.lastPathComponent).filter { code in
                rows(withCode: code).contains { PlanMatcher.contains(fileTokens, PlanMatcher.tokens($0.name)) }
            }
        }
        guard codes.count == 1, let code = codes.first else { return }
        // The file's link: a few tries (a dropped request mustn't lose the link), then built from its project.
        var url: String?
        for attempt in 0..<3 where url == nil {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2 * attempt)) }
            if let item = try? await FrameIO.shared.item(account: account, kind: "files", id: fileID) {
                url = item.viewURL ?? item.projectID.map { "https://next.frame.io/project/\($0)/view/\(fileID)" }
            }
        }
        guard let url else { return }
        // Uploads finish one file at a time: one recompute for a burst, not one per file (main thread, maybe playback).
        queueQC(rows(withCode: code), quiet: true, refresh: false) { item in
            item[.frameio] = url
            item[.uploaded] = Self.uploadStamp(Date())
        }
        scheduleRecompute()
    }

    /// Files listed on Frame.io (the browser, the favourites crawl): a row without a link gets the file whose name holds
    /// its code, when exactly one such file was in the listing (stacks: the stack, so the link survives new versions).
    /// Only into a sheet that has a Frame.io column, and never over a link already there.
    func frameIOListed(_ items: [FrameIO.Item], folder: String?) {
        guard config != nil else { return }
        // Browsing before the plan was opened this session: load its cached rows once, then look again.
        if rows.isEmpty, !loadedFromDisk {
            Task { await self.loadCachedIfNeeded(); if !self.rows.isEmpty { self.frameIOListed(items, folder: folder) } }
            return
        }
        // Bound to a Frame.io folder: listings outside its tree aren't the plan's (no links, no extras from them).
        guard inPlanTree(folder) else { return }
        recordListing(items, folder: folder)
        // Found while browsing: only into a sheet with the QCpie tab (it's set up on purpose; links wait in the outbox
        // while this Mac is signed out).
        guard hasQCTab, !rows.isEmpty else { return }
        // Candidates per code: files whose name holds the code, plus files named exactly like a row without its code
        // ("…_20s" for "…_20s_KL0140") or exactly like the local file matched to the row: names without a code.
        let names = exactNameIndex()
        let listed = items.filter { !$0.isFolder && $0.viewURL != nil }
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let decisions = Self.linkDecisions(
            files: listed.map { (id: $0.id, name: Self.listedName($0)) },
            codesInName: { self.codes(inFileNamed: $0) }, localNames: names.local, bareNames: names.bare,
            rows: { self.rows(withCode: $0) }, isLinked: { !self.frameioLink($0).isEmpty },
            localFiles: { self.match.result($0).files.map(\.lastPathComponent) })
        var queued = false
        for decision in decisions {
            guard let item = byID[decision.fileID], let url = item.viewURL else { continue }
            let targets = rows(withCode: decision.code)
            let date = Self.listedDate(item)
            guard decision.certain else {
                suggest(LinkSuggestion(code: targets.first?.code ?? decision.code, rowName: targets.first?.name ?? "",
                                       fileName: Self.listedName(item), url: url, fileID: item.id.lowercased(), date: date,
                                       reason: decision.reason))
                continue
            }
            if linkSuggestions[decision.code] != nil { linkSuggestions[decision.code] = nil }   // a dictionary write publishes even when nothing changes
            queueQC(targets, quiet: true, refresh: false) { entry in
                entry[.frameio] = url
                if let date, targets.allSatisfy({ self.shown(.uploaded, $0).isEmpty }) { entry[.uploaded] = Self.uploadStamp(date) }
            }
            queued = true
        }
        // Rows already linked to a listed version stack: a version added since (on Frame.io, by anyone) moves Uploaded
        // on, so a local file exported before it isn't flagged as newer than Frame.io's.
        for item in items where item.isVersionStack {
            guard let url = item.viewURL, let updated = Self.listedDate(item) else { continue }
            let linked = rows.filter { $0.code != nil && frameioLink($0) == PlanGrid.normalized(url) }
            guard !linked.isEmpty else { continue }
            let recorded = linked.compactMap { PlanUpload.date(shown(.uploaded, $0)) }.max()
            guard recorded.map({ updated > $0.addingTimeInterval(60) }) ?? true else { continue }
            queueQC(linked, quiet: true, refresh: false) { entry in entry[.uploaded] = Self.uploadStamp(updated) }
            queued = true
        }
        // One recompute and redraw for the whole listing, not one per row.
        if queued { recomputeStates(); publishGrids() }
    }

    struct LinkDecision: Equatable, Sendable {
        /// Lower-cased code of the row(s).
        let code: String
        let fileID: String
        /// Linked by itself; otherwise suggested with `reason`.
        let certain: Bool
        let reason: String
    }

    /// Which rows a Frame.io listing's files belong to (pure: the fixture tests run real names through it). Candidates
    /// per code: files whose name holds the code, plus files without a code named exactly like the local file matched
    /// to a row (`localNames`) or a row's name without its code (`bareNames`), when that points to one row. Rows that
    /// already have a link are left alone. One file must fit the row (its name holds the row's name, is the row's name
    /// without the code, or is its local file's name); of several (a "_v2" beside the original), only one named
    /// exactly like the row. Certain = one file, a code in its name, and the row's name in it; anything else is a
    /// suggestion. Codes repeat across campaigns, so a code alone never links.
    nonisolated static func linkDecisions(files: [(id: String, name: String)], codesInName: (String) -> Set<String>,
                                          localNames: [String: Set<String>], bareNames: [String: Set<String>],
                                          rows: (String) -> [PlanRow], isLinked: (PlanRow) -> Bool,
                                          localFiles: (PlanRow) -> [String]) -> [LinkDecision] {
        var candidates: [String: [(id: String, name: String)]] = [:]
        var byNameOnly = Set<String>()
        for file in files {
            var codes = codesInName(file.name)
            if codes.isEmpty {
                byNameOnly.insert(file.id)
                let key = nameKey(file.name)
                if let local = localNames[key], local.count == 1 { codes = local }
                else if let bare = bareNames[key], bare.count == 1 { codes = bare }
            }
            for code in codes { candidates[code, default: []].append(file) }
        }
        var out: [LinkDecision] = []
        for (code, list) in candidates.sorted(by: { $0.key < $1.key }) {
            let targets = rows(code)
            guard !targets.isEmpty, !targets.contains(where: isLinked) else { continue }
            func fits(_ name: String, exactly: Bool) -> Bool {
                let key = nameKey(name)
                return targets.contains { row in
                    let rowKey = nameKey(row.name)
                    let local = localFiles(row).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                    if exactly { return key == rowKey || key == nameKey(strippingCode(row)) || local }
                    return PlanMatcher.contains(PlanMatcher.tokens(key), PlanMatcher.tokens(rowKey)) || key == nameKey(strippingCode(row)) || local
                }
            }
            let chosen: (id: String, name: String)?
            if list.count == 1 { chosen = fits(list[0].name, exactly: false) ? list[0] : nil } else {
                let exact = list.filter { fits($0.name, exactly: true) }
                chosen = exact.count == 1 ? exact[0] : nil
            }
            guard let file = chosen else { continue }
            let certain = list.count == 1 && !byNameOnly.contains(file.id) && targets.contains { row in
                PlanMatcher.contains(PlanMatcher.tokens(nameKey(file.name)), PlanMatcher.tokens(nameKey(row.name)))
            }
            let reason = certain ? "" : byNameOnly.contains(file.id) ? "Same name, no code in the file's name."
                : list.count > 1 ? "One of \(list.count) files with this code: the one named like the row."
                : "The file's name holds the code but not the row's name."
            out.append(LinkDecision(code: code, fileID: file.id, certain: certain, reason: reason))
        }
        return out
    }

    /// A Frame.io file that probably belongs to a row, waiting for a click (`PlanLinkSuggestionsSheet`).
    struct LinkSuggestion: Identifiable, Equatable, Sendable {
        let code: String
        let rowName: String
        let fileName: String
        let url: String
        let fileID: String
        let date: Date?
        let reason: String
        var id: String { code.lowercased() }
        var dismissKey: String { "sx|\(code.lowercased())|\(fileID)" }
    }

    /// Rows that get a link any way (accepted, by hand, by an upload) leave the list in `queueQC`.
    var pendingSuggestions: [LinkSuggestion] {
        linkSuggestions.values.sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }

    private func suggest(_ suggestion: LinkSuggestion) {
        guard !dismissedMismatches.contains(suggestion.dismissKey), linkSuggestions[suggestion.id] != suggestion else { return }
        linkSuggestions[suggestion.id] = suggestion
    }

    func acceptSuggestions(_ ids: [String]) {
        for id in ids {
            guard let s = linkSuggestions[id] else { continue }
            let targets = rows(withCode: id)
            linkSuggestions[id] = nil
            // Never over a link that came in meanwhile.
            guard !targets.isEmpty, targets.allSatisfy({ frameioLink($0).isEmpty }) else { continue }
            queueQC(targets, refresh: false) { entry in
                entry[.frameio] = s.url
                if let date = s.date, targets.allSatisfy({ self.shown(.uploaded, $0).isEmpty }) { entry[.uploaded] = Self.uploadStamp(date) }
            }
        }
        recomputeStates()
        publishGrids()
    }

    func dismissSuggestions(_ ids: [String]) {
        let keys = ids.compactMap { linkSuggestions[$0]?.dismissKey }
        for id in ids { linkSuggestions[id] = nil }
        dismiss(keys)
    }
}
