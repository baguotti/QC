import AppKit
import VideoQCLib

/// What Send to Frame.io asks of Frame.io, apart so tests use a stub (and post nothing real).
protocol FrameIOCommentAPI: Sendable {
    func createComment(account: String, file: String, text: String, timestamp: Int?, completed: Bool) async throws -> String
}

extension FrameIO: FrameIOCommentAPI {}

/// QC notes → Frame.io comments (the Notes drawer's Send to Frame.io, and right-click → Send QC Notes in the browser).
/// Only notes written in QCpie go: never ones imported from Frame.io, never one already sent. Each comment lands on the
/// note's frame (`FrameIO.createComment`), resolved if the note is; who wrote the note and its replies go in the text.
/// The sent comment comes back on the next import as an echo of its note (`FrameIOCommentImport.notes(sent:)`), so
/// Frame.io replies and resolving reach the note instead of making a second one.
enum FrameIOCommentPush {
    static let signedOutMessage = "Signed out of Frame.io"

    struct Outcome: Sendable {
        var sent: [(note: UUID, comment: String)] = []
        var failures: [String] = []
    }

    /// Line Check's markers (red, `ContentView.syncScanResultsToNotes`): rebuilt with new ids on every scan, so they
    /// could never be told apart from ones already sent, and they're findings for the reviewer, not review notes.
    static let lineCheckAuthor = "Line QC"

    /// The notes that can be sent: not imported from Frame.io (by id, or marked "(Frame.io)" by an import on another
    /// Mac), not Line Check markers, not sent yet, with text.
    static func pending(_ notes: [QCFileNote], imported: Set<UUID>, sent: Set<UUID>) -> [QCFileNote] {
        notes.filter { note in
            !imported.contains(note.id) && !sent.contains(note.id) && !note.author.hasSuffix("(Frame.io)")
                && note.author != lineCheckAuthor && !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The comment's text: the note, then its author when it isn't the Frame.io account sending it, then its replies.
    static func text(for note: QCFileNote, signedInName: String?) -> String {
        var text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = note.author.trimmingCharacters(in: .whitespaces)
        if !author.isEmpty, author.caseInsensitiveCompare(signedInName?.trimmingCharacters(in: .whitespaces) ?? "") != .orderedSame {
            text += "\n— \(author)"
        }
        for reply in note.replies where !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n↳ \(reply.author): \(reply.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return text
    }

    /// Sends the notes in frame order. Over 90 notes, one every 0.65 s keeps under Frame.io's 100 comments a minute.
    /// Goes on after a failed note; stops when signed out. `didSend` records each comment as it's created. `timed`:
    /// false for a still image (no timestamp); a file Frame.io says takes none is sent without from then on.
    static func run(_ notes: [QCFileNote], account: String, file: String, signedInName: String?, timed: Bool = true,
                    api: FrameIOCommentAPI, pace: Duration = .milliseconds(650),
                    didSend: @Sendable (UUID, String) async -> Void) async -> Outcome {
        var outcome = Outcome()
        var timed = timed
        let paced = notes.count > 90
        for (index, note) in notes.sorted(by: { $0.frameIndex < $1.frameIndex }).enumerated() {
            if paced, index > 0 { try? await Task.sleep(for: pace) }
            do {
                let body = text(for: note, signedInName: signedInName)
                let comment: String
                do {
                    comment = try await api.createComment(account: account, file: file, text: body,
                                                          timestamp: timed ? max(0, note.frameIndex) : nil, completed: note.isResolved)
                } catch FrameIO.Failure.http(422, let message) where timed && message.localizedCaseInsensitiveContains("timestamp") {
                    timed = false
                    comment = try await api.createComment(account: account, file: file, text: body, timestamp: nil, completed: note.isResolved)
                }
                await didSend(note.id, comment)
                outcome.sent.append((note.id, comment))
            } catch FrameIO.Failure.signedOut {
                outcome.failures.append(signedOutMessage)
                break
            } catch {
                outcome.failures.append("\(note.timecode): \(UploadEngine.describe(error))")
            }
        }
        return outcome
    }

    static func summary(sent: Int, clips: Int, failures: [String]) -> String {
        var text = sent == 0 && failures.isEmpty ? "No notes to send"
            : "Sent \(sent) note\(sent == 1 ? "" : "s")\(clips > 1 ? " on \(clips) clips" : "") to Frame.io"
        if let first = failures.first {
            text += failures.count == 1 ? " · couldn't send \(first)" : " · \(failures.count) failed (\(first))"
        }
        return text
    }
}

extension FrameIOCommentPush {
    /// Asks before posting (comments are seen by everyone on the project): a sheet on the window, Send is the default.
    @MainActor
    static func confirm(notes: Int, clips: Int, onto target: String, then send: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = clips > 1 ? "Send \(notes) notes on \(clips) clips to Frame.io?"
            : "Send \(notes) note\(notes == 1 ? "" : "s") to Frame.io?"
        alert.informativeText = "They'll be added as comments on \(target), at each note's frame, where everyone on the project can "
            + "see them. Replies and resolving on Frame.io come back to the notes. Notes from Frame.io aren't sent back."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { send() }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
