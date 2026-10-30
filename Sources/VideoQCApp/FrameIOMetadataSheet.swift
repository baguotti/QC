import SwiftUI

/// Right-click → Edit Metadata… in the Frame.io browser: set Status, Assignee, Rating and custom fields on every
/// selected file at once (folders: every file in them; stacks: their current version). Each field starts at "No
/// change" with what the files have now beside it (read from up to 25 of them); only fields you change are written.
struct FrameIOMetadataSheet: View {
    struct Request: Identifiable {
        let id = UUID()
        let items: [FrameIO.Item]
        let account: String
        let project: String
    }

    let request: Request
    let isLightMode: Bool
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case loading, ready, applying, failed(String) }
    @State private var phase = Phase.loading
    @State private var fields: [MetadataField] = []
    @State private var users: [MetadataUser] = []
    @State private var files: [String] = []
    /// What the sampled files share per field id (nil: mixed).
    @State private var current: [String: MetadataValue?] = [:]
    @State private var edits: [String: MetadataEdit] = [:]
    @State private var texts: [String: String] = [:]

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var changed: Int { edits.values.filter { $0 != .unchanged }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Metadata")
                .font(.ui(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
            Group {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(height: 120)
                case .failed(let message):
                    Text(message).font(.ui(size: 12)).foregroundColor(palette.negative).frame(maxWidth: .infinity, minHeight: 80)
                case .ready, .applying:
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                                row(field)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(index.isMultiple(of: 2) ? palette.bgCardSubtle : Color.clear)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                    .studioBox(background: palette.bgMain, border: palette.borderLine)
                    .disabled(phase == .applying)
                }
            }
            HStack {
                Text(changed == 0 ? "Only the fields you change are written." : "\(changed) field\(changed == 1 ? "" : "s") will change.")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(phase == .applying ? "Applying…" : "Apply to \(files.count) File\(files.count == 1 ? "" : "s")") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase != .ready || changed == 0 || files.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .background(palette.bgPanel)
        .task { await load() }
    }

    private var subtitle: String {
        switch phase {
        case .loading: return "Reading the fields and the selected files…"
        default:
            let sampled = files.count > FrameIOMetadata.sampleLimit ? " (current values from the first \(FrameIOMetadata.sampleLimit))" : ""
            return "\(files.count) file\(files.count == 1 ? "" : "s")\(sampled). Fields left at No change keep each file's own value."
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ field: MetadataField) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(palette.accentBlue).frame(width: 5, height: 5)
                    .opacity((edits[field.id] ?? .unchanged) == .unchanged ? 0 : 1)
                Text(field.name)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .trailing)
            control(field)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func control(_ field: MetadataField) -> some View {
        switch field.fieldType {
        case "text", "long_text", "number":
            HStack(spacing: 6) {
                TextField(placeholder(field), text: Binding(get: { texts[field.id] ?? "" }, set: { setText($0, field: field) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 12))
                    .frame(width: 260)
                Button("Clear") { texts[field.id] = ""; edits[field.id] = .clear }
                    .font(.ui(size: 11))
                    .buttonStyle(.borderless)
            }
        default:
            Menu {
                Button("No change") { edits[field.id] = .unchanged }
                Button("Clear") { edits[field.id] = .clear }
                Divider()
                ForEach(choices(field), id: \.id) { choice in
                    Button { pick(choice.id, field: field) } label: {
                        if isPicked(choice.id, field: field) { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                    }
                }
            } label: {
                Text(menuLabel(field)).font(.ui(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private struct Choice { let id: String; let label: String }

    private func choices(_ field: MetadataField) -> [Choice] {
        switch field.fieldType {
        case "rating":
            return (1...(field.configuration?.maxValue ?? 5)).map { Choice(id: "\($0)", label: String(repeating: "★", count: $0)) }
        case "toggle":
            return [Choice(id: "on", label: "On"), Choice(id: "off", label: "Off")]
        default:
            return field.isUsers ? users.map { Choice(id: $0.id, label: $0.label) }
                : field.options.map { Choice(id: $0.id ?? "", label: $0.displayName) }
        }
    }

    private func pick(_ id: String, field: MetadataField) {
        switch field.fieldType {
        case "rating": edits[field.id] = .set(.number(Double(id) ?? 0))
        case "toggle": edits[field.id] = .set(.bool(id == "on"))
        default:
            guard field.isMulti else { edits[field.id] = .set(.ids([id])); return }
            var ids: [String] = []
            if case .set(.ids(let picked)) = edits[field.id] { ids = picked }
            if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
            edits[field.id] = ids.isEmpty ? .clear : .set(.ids(ids))
        }
    }

    private func isPicked(_ id: String, field: MetadataField) -> Bool {
        guard case .set(let value) = edits[field.id] else { return false }
        switch value {
        case .ids(let ids): return ids.contains(id)
        case .number(let number): return "\(Int(number))" == id
        case .bool(let flag): return (flag ? "on" : "off") == id
        default: return false
        }
    }

    /// "No change (Needs Review)", "No change (mixed)", "Clear", or the new value.
    private func menuLabel(_ field: MetadataField) -> String {
        switch edits[field.id] ?? .unchanged {
        case .unchanged: return "No change (\(currentText(field)))"
        case .clear: return "Clear"
        case .set(let value): return FrameIOMetadata.describe(value, field: field, users: users)
        }
    }

    private func placeholder(_ field: MetadataField) -> String {
        (edits[field.id] ?? .unchanged) == .clear ? "Will be cleared" : "No change (\(currentText(field)))"
    }

    private func currentText(_ field: MetadataField) -> String {
        guard let shared = current[field.id] else { return "unknown" }
        guard let shared else { return "mixed" }
        return FrameIOMetadata.describe(shared, field: field, users: users)
    }

    private func setText(_ text: String, field: MetadataField) {
        texts[field.id] = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            edits[field.id] = .unchanged
        } else if field.fieldType == "number" {
            edits[field.id] = Double(trimmed).map { .set(.number($0)) } ?? .unchanged
        } else {
            edits[field.id] = .set(.text(text))
        }
    }

    // MARK: Loading and applying

    private func load() async {
        do {
            async let definitions = FrameIO.shared.metadataFields(account: request.account)
            async let members = FrameIO.shared.projectUsers(account: request.account, project: request.project)
            let expanded = try await DownloadEngine.expand(request.items, account: request.account, api: FrameIO.shared,
                                                           retry: NetworkRetry(network: NetworkMonitor.shared))
            fields = FrameIOMetadata.ordered(try await definitions)
            users = (try? await members) ?? []
            files = Array(Set(expanded.map(\.fileID))).sorted()
            var samples: [[String: MetadataValue]] = []
            for file in files.prefix(FrameIOMetadata.sampleLimit) {
                if let values = try? await FrameIO.shared.metadataValues(account: request.account, file: file) { samples.append(values) }
            }
            // None read (rate limited, offline): the current values are unknown, not empty.
            current = samples.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: fields.map { ($0.id, FrameIOMetadata.common(samples, field: $0.id)) })
            phase = files.isEmpty ? .failed("There are no files in the selection.") : (fields.isEmpty ? .failed("This account has no editable metadata fields.") : .ready)
        } catch {
            phase = .failed("Couldn't read the metadata: \(UploadEngine.describe(error))")
        }
    }

    private func apply() {
        let values = FrameIOMetadata.values(edits, fields: fields)
        guard !values.isEmpty else { return }
        phase = .applying
        let request = request, files = files
        let bodies = stride(from: 0, to: files.count, by: FrameIOMetadata.batchSize).map { start in
            let batch = Array(files[start..<min(start + FrameIOMetadata.batchSize, files.count)])
            return (batch.count, try? FrameIOMetadata.body(files: batch, values: values))
        }
        Task {
            var done = 0
            var failure: String?
            for (count, body) in bodies {
                do {
                    guard let body else { throw FrameIO.Failure.unreadable }
                    try await FrameIO.shared.updateMetadata(account: request.account, project: request.project, body: body)
                    done += count
                } catch {
                    failure = UploadEngine.describe(error)
                    break
                }
            }
            if let failure {
                FrameIOBrowser.shared.notify(done == 0 ? "Couldn't update the metadata: \(failure)"
                                             : "Updated \(done) of \(files.count) files, then: \(failure)", isError: true)
            } else {
                FrameIOBrowser.shared.notify("Updated metadata on \(done) file\(done == 1 ? "" : "s")")
            }
            dismiss()
        }
    }
}
