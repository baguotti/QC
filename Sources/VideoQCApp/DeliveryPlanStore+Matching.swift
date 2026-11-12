import Foundation
import SwiftUI
import VideoQCLib

/// Changes since last seen, Inspect's files, matching them to rows and each row's state.
extension DeliveryPlanStore {
    // MARK: Changes

    private static func label(_ row: PlanRow) -> String {
        [row.name, row.value(.resolution), row.value(.placement)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func snapshot(_ rows: [PlanRow]) -> [String: SeenRow] {
        Dictionary(rows.map { ($0.id, SeenRow(label: label($0), values: $0.content)) }, uniquingKeysWith: { a, _ in a })
    }

    func recomputeChanges() {
        var result: [String: Change] = [:]
        for row in rows {
            guard let old = seen[row.id] else { result[row.id] = .added; continue }
            let now = row.content
            guard now != old.values else { continue }
            let fields = PlanField.allCases.filter { !$0.isTracking }.compactMap { field -> String? in
                let a = old.values[field.rawValue] ?? "", b = now[field.rawValue] ?? ""
                return a == b ? nil : "\(field.title): \(a.isEmpty ? "—" : a) → \(b.isEmpty ? "—" : b)"
            }
            result[row.id] = .changed(fields)
        }
        let present = Set(rows.map(\.id))
        let gone = seen.filter { !present.contains($0.key) }.map(\.value).sorted { $0.label < $1.label }
        if result != changes { changes = result }
        if gone != removed { removed = gone }
    }

    /// Accepts the sheet as it is now: highlights and the Removed list clear.
    func markSeen() {
        seen = Self.snapshot(rows)
        saveSeen()
        recomputeChanges()
    }

    func saveSeen() {
        guard let config else { return }
        let dir = Self.directory(config.link.sheetID)
        let seen = seen
        Task.detached(priority: .utility) {
            JSONFile.save(seen, to: dir.appendingPathComponent("seen.json"), log: .plan)
        }
    }

    /// The Inspect tab's measured files (called when its list changes; cheap when nothing changed).
    func setAssets(_ assets: [DeliverableAsset]) {
        let measured = assets.filter { $0.width > 0 || $0.durationSeconds > 0 }
        // Inspect updates its list once per file during loudness / end-frame checks (same files, new measurements):
        // dates already read for the same inspection of a file (`asset.id`) are kept, so only new or re-read files
        // are stat'ed (it was 1,000+ stats per finished file, maybe on a server).
        let known = Dictionary(measured.compactMap { asset in
            assetIDs[asset.fileURL] == asset.id ? filesByURL[asset.fileURL].map { (asset.fileURL, $0.modified) } : nil
        }, uniquingKeysWith: { a, _ in a })
        assetsTask?.cancel()
        assetsTask = Task {
            let (newFiles, content) = await Task.detached(priority: .utility) {
                let content = Dictionary(measured.compactMap { asset in PlanContent(asset).map { (asset.fileURL, $0) } },
                                         uniquingKeysWith: { a, _ in a })
                return (measured.map { asset -> PlanFile in
                    var file = PlanFile(asset)
                    if let date = known[asset.fileURL] {
                        file.modified = date
                    } else {
                        file.modified = (try? FileManager.default.attributesOfItem(atPath: asset.fileURL.path))?[.modificationDate] as? Date
                    }
                    return file
                }, content)
            }.value
            guard !Task.isCancelled else { return }
            assetIDs = Dictionary(measured.map { ($0.fileURL, $0.id) }, uniquingKeysWith: { a, _ in a })
            // A finished check changes only what was found: the rows' flags, not the matching.
            let contentChanged = content != fileContent
            if contentChanged {
                fileContent = content
                contentFlagCache = contentFlagCache.filter { content[$0.key] != nil }
            }
            guard newFiles != files else {
                if contentChanged { recomputeStates(); publishGrids() }
                return
            }
            files = newFiles
            filesByURL = Dictionary(newFiles.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            if hasFiles != !files.isEmpty { hasFiles = !files.isEmpty }
            rematch()
        }
    }

    /// A row's files with size and date (checks belong to a file version).
    func fileStamps(_ row: PlanRow) -> [(url: URL, size: Int64, modified: Date?)] {
        match.result(row).files.map { url in (url, filesByURL[url]?.bytes ?? 0, filesByURL[url]?.modified) }
    }

    func rematch() {
        let rows = rows, files = files
        matchTask?.cancel()
        matchTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { PlanMatcher.match(rows: rows, files: files) }.value
            guard !Task.isCancelled, let self else { return }
            if result != self.match { self.match = result }
            self.matchRevision &+= 1
            self.recomputeStates()
        }
    }



    func setHealth(_ change: (inout PlanHealth) -> Void) {
        var next = health
        change(&next)
        guard next != health else { return }
        if next.readError != health.readError {
            if let error = next.readError { Log.plan.error("Reading the sheet: \(error)") } else if health.readError != nil { Log.plan.notice("Reading the sheet works again") }
        }
        if next.writeError != health.writeError {
            if let error = next.writeError { Log.plan.error("Writing to the sheet: \(error)") } else if health.writeError != nil { Log.plan.notice("Writing to the sheet works again") }
        }
        health = next
    }

    /// The outbox's counts in `health` (after every change to it).
    func noteOutbox() {
        let unsent = outbox.unsent
        let written = outbox.records.values.filter { $0.written != nil }.count + outbox.cells.filter { $0.written != nil }.count
        setHealth {
            $0.waiting = unsent.records.count + unsent.cells.count
            $0.confirming = written
            if $0.waiting == 0 { $0.retrying = false }
        }
    }

    /// The health popover's Try Again.
    func retrySending() {
        retryDelay = 0
        scheduleFlush(after: 0)
    }

    func recomputeStates() {
        statesRevision &+= 1
        // No sheet linked: nothing is "in" or "not in" a plan. Matching still ran (every file came out as an extra),
        // which put a "Not in plan" pill on every Inspect file and its chips over the table.
        guard config != nil else {
            if !fileIndex.isEmpty { fileIndex = [:] }
            if !localExtras.isEmpty { localExtras = [] }
            return
        }
        let dates = Dictionary(files.compactMap { f in f.modified.map { (f.url, $0) } }, uniquingKeysWith: { a, _ in a })
        var newStates: [String: PlanRowState] = [:]
        var index: [URL: PlanFileInfo] = [:]
        var batchNames = Set<String>()
        var perBatch: [String: (total: Int, done: Int, dropped: Int)] = [:]
        var uploads: [PlanUpload] = []
        uploads.reserveCapacity(rows.count)
        var mismatchCounts: [PlanMismatch: Int] = [:]
        var mismatchTotal = 0
        // Links first (pending writes win): the listed folders' extras and Frame.io's sizes depend on all of them.
        let overlay = outbox.overlay
        let links = rows.map { row in
            PlanGrid.normalized(row.code.flatMap { overlay[$0.lowercased()]?[.frameio] } ?? row.value(.frameio))
        }
        // Suggestions for rows linked since (by hand, an upload, another Mac through the sheet) leave: accepting one
        // would replace that link.
        if !linkSuggestions.isEmpty {
            var linkedCodes = Set<String>()
            for (row, link) in zip(rows, links) where !link.isEmpty { if let code = row.code?.lowercased() { linkedCodes.insert(code) } }
            let kept = linkSuggestions.filter { !linkedCodes.contains($0.key) }
            if kept.count != linkSuggestions.count { linkSuggestions = kept }
        }
        // By Frame.io id, not URL text: links pasted by hand can differ in form, and a row may link a stack's current
        // version while the folder lists the stack.
        let linked = Set(links.compactMap(Self.frameIOID))
        var listed: [String: ListedFile] = [:]
        var unlinked: [ListedFile] = []
        // Bound to a Frame.io folder: every folder of its tree (it was scanned whole). Otherwise only folders holding a
        // linked file (whatever happened to be browsed).
        let bound = config?.frameioRoot != nil
        for files in frameioFolders.values where bound || files.contains(where: { $0.isLinked(in: linked) }) {
            for file in files {
                for id in file.ids { listed[id] = file }
                if !file.isLinked(in: linked) { unlinked.append(file) }
            }
        }
        var linkedCodes: [String: Bool] = [:]
        if !unlinked.isEmpty {
            for (row, link) in zip(rows, links) {
                guard let code = row.code?.lowercased() else { continue }
                linkedCodes[code] = (linkedCodes[code] ?? true) && !link.isEmpty
            }
        }
        var dismissedNow = 0
        var extras = unlinked.filter { file in
            guard dismissedMismatches.contains("fx|" + (Self.frameIOID(file.url) ?? file.url)) else { return true }
            dismissedNow += 1
            return false
        }.map { PlanFrameIOExtra(name: $0.name, url: $0.url, note: extraNote($0.name, linkedCodes: linkedCodes)) }
        extras.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // "Done but not on Frame.io" only for plans that use Frame.io links at all.
        let tracksFrameIO = links.contains { !$0.isEmpty }
        for (row, link) in zip(rows, links) {
            let result = match.result(row)
            let pending = row.code.flatMap { overlay[$0.lowercased()] }
            var state = PlanStatusResolver.resolve(match: result.status, hasFiles: !result.files.isEmpty,
                                                   qc: pending?[.qcStatus] ?? row.value(.qcStatus),
                                                   updated: pending?[.qcUpdated] ?? row.value(.qcUpdated),
                                                   fileDates: result.files.compactMap { dates[$0] })
            var found: [(kind: PlanMismatch, flag: String)] = []
            if !link.isEmpty {
                state.upload = .uploaded
                // The local file changed after the upload (a minute's grace: the upload stamp has no seconds).
                let uploadedOn = pending?[.uploaded] ?? row.value(.uploaded)
                if let when = PlanUpload.date(uploadedOn), let newest = result.files.compactMap({ dates[$0] }).max(),
                   newest > when.addingTimeInterval(60) {
                    state.upload = .stale
                    found.append((.differs, "Changed after its upload to Frame.io (\(uploadedOn)): Frame.io has an older version."))
                } else if result.files.count == 1, let local = result.files.first, QCUtilities.mediaKind(of: local) != .image,
                          let remote = Self.frameIOID(link).flatMap({ listed[$0] }), remote.size > 0,
                          let bytes = filesByURL[local]?.bytes, bytes > 0, bytes != remote.size,
                          (remote.name as NSString).pathExtension.lowercased() == local.pathExtension.lowercased() {
                    // Same kind of file, another size: Frame.io holds another version (or another file).
                    state.upload = .stale
                    found.append((.differs, "Frame.io's file is \(Self.byteText(remote.size)), this one \(Self.byteText(bytes)): Frame.io has another version."))
                }
            } else if tracksFrameIO, state.state.isDone {
                found.append((.notUploaded, "\(state.state.title), but not on Frame.io."))
            }
            // The picture and sound against the row, once the checks have run (not for dropped rows).
            var contentFlags: [URL: [PlanContentFlag]] = [:]
            if state.state != .dropped {
                for url in result.files {
                    guard let content = fileContent[url] else { continue }
                    let flags: [PlanContentFlag]
                    if let cached = contentFlagCache[url], cached.content == content, cached.row == row {
                        flags = cached.flags
                    } else {
                        flags = PlanContentCheck.flags(row, content)
                        contentFlagCache[url] = (row, content, flags)
                    }
                    guard !flags.isEmpty else { continue }
                    contentFlags[url] = flags
                    let prefix = result.files.count > 1 ? "\(url.lastPathComponent): " : ""
                    for flag in flags { found.append((.content, prefix + flag.text)) }
                }
            }
            // Dismissed ones stay quiet until what they were about changes (another link, a newer local file).
            let newest = result.files.compactMap { dates[$0] }.max()
            var dismissedKinds = Set<PlanMismatch>()
            for (kind, flag) in found {
                if !dismissedMismatches.isEmpty, dismissedMismatches.contains(Self.mismatchKey(row.id, kind, link: link, newest: newest)) {
                    if dismissedKinds.insert(kind).inserted { dismissedNow += 1 }
                    continue
                }
                if !state.mismatches.contains(kind) { state.mismatches.append(kind) }
                state.flags.append(flag)
            }
            if !state.mismatches.contains(.content) { contentFlags = [:] }   // dismissed
            for kind in state.mismatches { mismatchCounts[kind, default: 0] += 1 }
            if !state.mismatches.isEmpty { mismatchTotal += 1 }
            newStates[row.id] = state
            let rowBatch = PlanGrid.normalized(pending?[.batch] ?? row.value(.batch))
            if !rowBatch.isEmpty { batchNames.insert(rowBatch) }
            perBatch[rowBatch, default: (0, 0, 0)].total += 1
            if state.state.isDone { perBatch[rowBatch, default: (0, 0, 0)].done += 1 }
            if state.state == .dropped { perBatch[rowBatch, default: (0, 0, 0)].dropped += 1 }
            uploads.append(state.upload)
            for url in result.files where index[url] == nil {
                index[url] = PlanFileInfo(code: row.code ?? "", line: row.line, rowID: row.id, state: state.state,
                                          batch: rowBatch, frameio: link, upload: state.upload, mismatches: state.mismatches,
                                          contentFlags: contentFlags[url] ?? [], noSound: PlanContentCheck.isNo(row.value(.sound)),
                                          channel: PlanGrid.normalized(row.value(.channel)), text: row.searchText)
            }
        }
        let sortedBatches = PlanBatch.sorted(batchNames)
        if sortedBatches != batches { batches = sortedBatches }
        // The filter menus' counts, once per recompute rather than on every redraw of the plan (each Inspect selection).
        var counts = PlanCounts(
            batches: sortedBatches.map { name in
                let c = perBatch[name] ?? (0, 0, 0)
                return PlanBatchFilter.Item(name: name, count: c.total, done: c.done, live: c.total - c.dropped)
            },
            unbatched: perBatch[""]?.total ?? 0,
            uploads: PlanUploadFilter.counts(uploads))
        if !extras.isEmpty { mismatchCounts[.frameioExtra] = extras.count }
        let local = match.extras.filter { !dismissedMismatches.contains("lx|" + $0.path) }
        dismissedNow += match.extras.count - local.count
        if !local.isEmpty { mismatchCounts[.localExtra] = local.count }
        counts.mismatches = mismatchCounts
        counts.mismatchTotal = mismatchTotal + extras.count + local.count
        counts.dismissed = dismissedNow
        if local != localExtras { localExtras = local }
        if counts != planCounts { planCounts = counts }
        if extras != frameioExtras { frameioExtras = extras }
        // Inspect's "Here, Not in the Plan" filter skips the dismissed ones too.
        let flagged = Set(local)
        for url in match.extras {
            index[url] = PlanFileInfo(code: "", line: 0, rowID: nil, state: nil, mismatches: flagged.contains(url) ? [.localExtra] : [])
        }
        if newStates != states { states = newStates }
        if index != fileIndex { fileIndex = index }
    }

    /// The tab's QC Status column (0-based), when it has one.
    func statusColumn(gid: String) -> Int? { gridColumn(.qcStatus, gid: gid) }

    /// A field's column in the Sheet view, found by header text: the view leaves hidden and collapsed columns out, so
    /// the sheet's column numbers (`headers`, from the CSV) can point at the wrong one. Nil when hidden in the view.
    func gridColumn(_ field: PlanField, gid: String) -> Int? {
        guard let header = headers[gid], let column = header.columns[field] else { return nil }
        guard let grid = readGrids[gid] else { return column }
        if PlanField.detect(grid.text(line: header.line, column: column) ?? "") == field { return column }
        return grid.columnWidths.indices.first { PlanField.detect(grid.text(line: header.line, column: $0) ?? "") == field }
    }

    func state(_ row: PlanRow) -> PlanRowState { states[row.id] ?? PlanRowState(state: .missing) }

    /// The QC note as shown (a pending edit wins).
    func note(_ row: PlanRow) -> String {
        shown(.qcNote, row)
    }

    // MARK: Statuses

    /// Sets (nil: clears) the QC status of rows, stamped with time and reviewer. Shown at once, written in one batch.
    func setStatus(_ status: PlanQCStatus?, rowIDs: [String]) {
        let ids = Set(rowIDs)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item[.qcStatus] = status?.title ?? "" }
    }

    func setNote(_ note: String, rowID: String) {
        queueQC(rows.filter { $0.id == rowID }) { item in item[.qcNote] = note }
    }

    /// Sets ("" clears) the batch of rows. Shown at once, written with the statuses (by code, every tab).
    func setBatch(_ batch: String, rowIDs: [String]) {
        let ids = Set(rowIDs)
        let value = PlanGrid.normalized(batch)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item[.batch] = value }
    }

    /// QC Updated as shown (a pending edit wins).
    func qcUpdated(_ row: PlanRow) -> String { shown(.qcUpdated, row) }
    func qcStatusText(_ row: PlanRow) -> String { shown(.qcStatus, row) }

    /// The batch as shown (a pending edit wins), normalised; "" when none.
    func batch(_ row: PlanRow) -> String {
        PlanGrid.normalized(shown(.batch, row))
    }

    /// A column QCpie writes, as shown: a pending edit wins over the last read.
    func shown(_ field: PlanField, _ row: PlanRow) -> String {
        row.code.flatMap { outbox.records[$0.lowercased()]?.values[field.rawValue] } ?? row.value(field)
    }
}
