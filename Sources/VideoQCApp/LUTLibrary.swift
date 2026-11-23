import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VideoQCLib

/// The `.cube` LUTs in `Application Support/QCpie/LUTs` and which file uses which. The LUTs bundled with the app are
/// copied there once each (one the user deletes stays deleted); any `.cube` the user adds shows up when QCpie is next
/// brought to the front. Assignments are by file path, saved in UserDefaults (`lutAssignments`: path → LUT name, or
/// the absolute path of a custom LUT the user chose not to save to the folder).
@MainActor
final class LUTLibrary {
    static let shared = LUTLibrary()

    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QCpie/LUTs", isDirectory: true)
    private static let assignmentsKey = "lutAssignments"
    private static let seededKey = "lutSeeded"

    /// LUT names (file names without `.cube`), sorted as Finder does.
    private(set) var names: [String] = []
    private var assignments: [String: String]
    private var cache: [String: CubeLUT] = [:]
    private var loads: [String: Task<CubeLUT?, Never>] = [:]
    /// LUTs that failed to read: not tried (or logged) again on every load until QCpie next comes to the front.
    private var unreadable = Set<String>()
    private var scan: Task<Void, Never>? = nil

    private init() {
        assignments = UserDefaults.standard.dictionary(forKey: Self.assignmentsKey) as? [String: String] ?? [:]
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LUTLibrary.shared.refresh() }
        }
    }

    // MARK: Assignments

    func lutName(for url: URL) -> String? { assignments[url.standardizedFileURL.path] }

    /// The LUT shown on `url`: its assignment, unless that LUT failed to read (then none is applied).
    func appliedLUTName(for url: URL) -> String? {
        lutName(for: url).flatMap { unreadable.contains($0) ? nil : $0 }
    }

    /// A LUT as people read it: a custom LUT kept outside the folder is stored by path.
    nonisolated static func displayName(_ key: String) -> String {
        key.hasPrefix("/") ? URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent : key
    }

    nonisolated private static func fileURL(for key: String) -> URL {
        key.hasPrefix("/") ? URL(fileURLWithPath: key) : folder.appendingPathComponent(key + ".cube")
    }

    /// `name` nil removes the files' LUT.
    func assign(_ name: String?, to urls: [URL]) {
        for url in urls { assignments[url.standardizedFileURL.path] = name }
        UserDefaults.standard.set(assignments, forKey: Self.assignmentsKey)
    }

    // MARK: Reading LUTs

    func cachedLUT(named name: String) -> CubeLUT? { cache[name] }

    /// Read off the main thread once, then cached. nil (logged) when the file is gone or unreadable.
    func lut(named name: String) async -> CubeLUT? {
        if let cube = cache[name] { return cube }
        guard !unreadable.contains(name) else { return nil }
        let task = loads[name] ?? Task.detached(priority: .userInitiated) {
            let url = LUTLibrary.fileURL(for: name)
            do { return try CubeLUT.read(url) } catch {
                Log.player.error("Reading LUT \(url.lastPathComponent) failed", error)
                return nil
            }
        }
        loads[name] = task
        let cube = await task.value
        loads[name] = nil
        if let cube { cache[name] = cube } else { unreadable.insert(name) }
        return cube
    }

    // MARK: Folder

    /// Copies bundled LUTs not copied before, then lists the folder (off the main thread). A changed file is read again.
    func refresh() {
        unreadable = []
        guard scan == nil else { rescan = true; return }
        let seeded = Set(UserDefaults.standard.stringArray(forKey: Self.seededKey) ?? [])
        scan = Task { [weak self] in
            let (names, newlySeeded, dates) = await Task.detached(priority: .utility) { Self.scanFolder(seeded: seeded) }.value
            guard let self else { return }
            self.scan = nil
            if !newlySeeded.isEmpty {
                UserDefaults.standard.set(Array(seeded.union(newlySeeded)).sorted(), forKey: Self.seededKey)
            }
            // A LUT replaced on disk under the same name is read again next time.
            for (name, date) in dates where self.modified[name] != date {
                if self.modified[name] != nil { self.cache[name] = nil }
                self.modified[name] = date
            }
            if self.names != names { self.names = names }
            if self.rescan { self.rescan = false; self.refresh() }   // a LUT was saved while listing
        }
    }
    private var modified: [String: Date] = [:]
    private var rescan = false

    nonisolated private static func scanFolder(seeded: Set<String>) -> ([String], [String], [String: Date]) {
        let fm = FileManager.default
        var newlySeeded: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("LUTs", isDirectory: true),
           let files = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "cube" && !seeded.contains(file.lastPathComponent) {
                let target = folder.appendingPathComponent(file.lastPathComponent)
                let copied: Void? = Log.player.attempt("Installing LUT \(file.lastPathComponent)") {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
                }
                if copied != nil { newlySeeded.append(file.lastPathComponent) }
            }
        }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var dates: [String: Date] = [:]
        let names = files.filter { $0.pathExtension.lowercased() == "cube" }.map { file -> String in
            let name = file.deletingPathExtension().lastPathComponent
            dates[name] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return name
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (names, newlySeeded, dates)
    }

    /// Right-click → LUT → Custom LUT…: picks a `.cube`, checks it reads, then asks whether to save it to the LUTs
    /// folder (it then shows in the menu for every clip) or use it for these files only (kept where it is, by path).
    func chooseCustom(for urls: [URL], onAssigned: @escaping ([URL]) -> Void) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a LUT"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            let read = await Task.detached(priority: .userInitiated) { Result { try CubeLUT.read(source) } }.value
            let cube: CubeLUT
            switch read {
            case .success(let c): cube = c
            case .failure(let error):
                Log.player.error("Reading LUT \(source.lastPathComponent) failed", error)
                let alert = NSAlert()
                alert.messageText = "QCpie can't use “\(source.lastPathComponent)”"
                alert.informativeText = (error as? CubeLUT.ReadError)?.description ?? error.localizedDescription
                alert.runModal()
                return
            }
            let ask = NSAlert()
            ask.messageText = "Save “\(cube.name)” to your LUTs?"
            ask.informativeText = "Saved LUTs are listed in the LUT menu for every clip. Otherwise it's used for "
                + (urls.count == 1 ? "this clip" : "these \(urls.count) clips") + " only, from where it is now."
            ask.addButton(withTitle: "Save to LUTs")
            ask.addButton(withTitle: "Use Without Saving")
            ask.addButton(withTitle: "Cancel")
            let answer = ask.runModal()
            guard answer != .alertThirdButtonReturn else { return }
            var key = source.standardizedFileURL.path
            if answer == .alertFirstButtonReturn {
                let saved = await Task.detached(priority: .userInitiated) { Self.copyIntoFolder(source) }.value
                if let saved { key = saved }
                refresh()
            }
            cache[key] = cube
            assign(key, to: urls)
            onAssigned(urls)
        }
    }

    /// Copies `source` into the folder (a name already used by another file gets " 2", " 3"…). Returns its name,
    /// or nil (logged) when the copy failed: the LUT is then used from where it is.
    nonisolated private static func copyIntoFolder(_ source: URL) -> String? {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        var name = base
        var n = 1
        while fm.fileExists(atPath: folder.appendingPathComponent(name + ".cube").path) {
            if fm.contentsEqual(atPath: folder.appendingPathComponent(name + ".cube").path, andPath: source.path) { return name }
            n += 1
            name = "\(base) \(n)"
        }
        let copied: Void? = Log.player.attempt("Saving LUT \(source.lastPathComponent)") {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: folder.appendingPathComponent(name + ".cube"))
        }
        return copied == nil ? nil : name
    }

    func revealFolder() {
        Log.player.attempt("Creating the LUTs folder") {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(Self.folder)
    }
}

/// "LUT" submenu for files (a queue row, Inspect's selection): None, every LUT in the folder, and the folder.
/// Not observing the library: rows of long lists never subscribe to a singleton (AGENTS.md). The names are read when
/// the row is drawn, the files when an item is chosen, and there is no checkmark (it could be out of date on a row
/// that hasn't redrawn since): the Player's LUT button names the loaded clip's LUT.
struct LUTMenu: View {
    let title: String
    let files: () -> [URL]
    let onAssigned: ([URL]) -> Void

    var body: some View {
        Menu(title) {
            Button("None") { assign(nil) }
            let names = LUTLibrary.shared.names
            if !names.isEmpty { Divider() }
            ForEach(names, id: \.self) { name in
                Button(name) { assign(name) }
            }
            Divider()
            Button("Custom LUT…") { LUTLibrary.shared.chooseCustom(for: files(), onAssigned: onAssigned) }
            Button("Show LUTs Folder") { LUTLibrary.shared.revealFolder() }
        }
    }

    private func assign(_ name: String?) {
        let urls = files()
        LUTLibrary.shared.assign(name, to: urls)
        onAssigned(urls)
    }
}
