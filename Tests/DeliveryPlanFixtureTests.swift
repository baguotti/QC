import Foundation
import Testing
@testable import QCpie

// Names through the Frame.io linking rules: a plan (`_TEST/DeliveryPlanMock/_PLAN.csv`, a test sheet as read: the
// real naming isn't final, swap in new files as it changes) and the mock delivery's file names as a Frame.io listing, checked against `_ANSWER_KEY.csv`. `_TEST` is
// local and git-ignored: without it the test does nothing.
@Suite("Delivery Plan · fixtures")
struct DeliveryPlanFixtureTests {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("_TEST")

    @Test("Mock delivery as a Frame.io listing: right files link by themselves, doubtful ones are only suggested",
          arguments: ["DeliveryPlanMock", "DeliveryPlanMock_v2"])
    func linking(_ folder: String) throws {
        let root = Self.tests.appendingPathComponent(folder)
        guard let csv = try? String(contentsOf: root.appendingPathComponent("_PLAN.csv"), encoding: .utf8),
              let key = try? String(contentsOf: root.appendingPathComponent("_ANSWER_KEY.csv"), encoding: .utf8) else { return }
        // Placeholder data: the real naming isn't final, so this checks the rules' behaviour per case, not any count.
        let rows = PlanParser.rows(csv: csv, tab: "Plan")
        guard !rows.isEmpty else { return }
        var byCode: [String: [PlanRow]] = [:]
        for row in rows { if let code = row.code?.lowercased() { byCode[code, default: []].append(row) } }
        let names = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .map { ($0 as NSString).lastPathComponent }.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && ($0 as NSString).pathExtension != "" }
        let files = names.map { (id: $0, name: $0) }
        let decisions = DeliveryPlanStore.linkDecisions(
            files: files,
            codesInName: { name in
                let tokens = PlanMatcher.tokens((name as NSString).deletingPathExtension)
                return Set(tokens.filter { byCode[$0] != nil })
            },
            localNames: [:], bareNames: [:], rows: { byCode[$0] ?? [] }, isLinked: { _ in false }, localFiles: { _ in [] })
        let certain = Dictionary(decisions.filter(\.certain).map { ($0.fileID, $0.code) }, uniquingKeysWith: { a, _ in a })
        let suggested = Set(decisions.filter { !$0.certain }.map(\.fileID))

        var counts: [String: (certain: Int, suggested: Int, none: Int)] = [:]
        for line in PlanParser.csv(key).dropFirst() where line.count >= 3 {
            let (file, kind, code) = (line[0], line[1], line[2].lowercased())
            guard names.contains(file) else { continue }
            let linkedTo = certain[file]
            counts[kind, default: (0, 0, 0)].certain += linkedTo != nil ? 1 : 0
            counts[kind, default: (0, 0, 0)].suggested += suggested.contains(file) ? 1 : 0
            counts[kind, default: (0, 0, 0)].none += linkedTo == nil && !suggested.contains(file) ? 1 : 0
            switch kind {
            case "ok", "no_audio", "wrong_format", "wrong_len", "wrong_res":
                // Right name and code (the specs don't matter for linking): linked to its own row.
                #expect(linkedTo == code, "\(file) should link to \(code), got \(linkedTo ?? "nothing")")
            case "wrong_code", "extra":
                #expect(linkedTo == nil || linkedTo == code, "\(file) linked to \(linkedTo ?? "")")
                if kind == "extra" { #expect(linkedTo == nil, "\(file) is not in the plan") }
            case "duplicate", "no_code":
                #expect(linkedTo == nil, "\(file) is doubtful and mustn't link by itself")
            default: break
            }
        }
        print("Fixture linking (\(folder)):", counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
    }
}
