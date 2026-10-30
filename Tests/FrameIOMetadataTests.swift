import Foundation
import Testing
@testable import QCpie

@Suite("Frame.io bulk metadata")
struct FrameIOMetadataTests {
    private func field(_ name: String, _ type: String, mutable: Bool = true, options: [String] = []) throws -> MetadataField {
        let json: [String: Any] = ["id": "id-\(name)", "name": name, "field_type": type, "mutable": mutable,
                                   "field_configuration": ["options": options.map { ["id": "opt-\($0)", "display_name": $0] }]]
        return try JSONDecoder().decode(MetadataField.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("Status, Assignee, Rating first; read-only and date fields left out")
    func order() throws {
        let fields = [try field("Notes", "long_text"), try field("Rating", "rating"), try field("Codec", "text", mutable: false),
                      try field("Assignee", "user_single"), try field("Due", "date"), try field("Status", "select"), try field("Keywords", "select_multi")]
        #expect(FrameIOMetadata.ordered(fields).map(\.name) == ["Status", "Assignee", "Rating", "Keywords", "Notes"])
    }

    @Test("Values read as Frame.io returns them (measured shapes)")
    func decode() throws {
        let json = """
        [{"field_definition_id": "s", "field_type": "select", "mutable": true, "value": [{"id": "e1", "display_name": "Needs Review"}]},
         {"field_definition_id": "a", "field_type": "user_single", "mutable": true, "value": [{"id": "u1", "type": "user"}]},
         {"field_definition_id": "r", "field_type": "rating", "mutable": true, "value": 3},
         {"field_definition_id": "n", "field_type": "long_text", "mutable": true, "value": "QCpie"},
         {"field_definition_id": "k", "field_type": "select_multi", "mutable": true, "value": []},
         {"field_definition_id": "x", "field_type": "long_text", "mutable": true, "value": null}]
        """
        let entries = try JSONDecoder().decode([MetadataValue.Entry].self, from: Data(json.utf8))
        #expect(entries.map(\.value) == [.ids(["e1"]), .ids(["u1"]), .number(3), .text("QCpie"), .empty, .empty])
    }

    @Test("Write formats, clearing included (null is refused by Frame.io)")
    func payload() throws {
        let status = try field("Status", "select"), assignee = try field("Assignee", "user_single")
        let rating = try field("Rating", "rating"), notes = try field("Notes", "long_text")
        #expect(FrameIOMetadata.payload(.set(.ids(["e1"])), for: status) as? [String] == ["e1"])
        #expect(FrameIOMetadata.payload(.set(.ids(["u1"])), for: assignee) as? [[String: String]] == [["id": "u1", "type": "user"]])
        #expect(FrameIOMetadata.payload(.set(.number(3)), for: rating) as? Int == 3)
        #expect(FrameIOMetadata.payload(.clear, for: status) as? [Any] != nil)
        #expect(FrameIOMetadata.payload(.clear, for: rating) as? Int == 0)
        #expect(FrameIOMetadata.payload(.clear, for: notes) as? String == "")
        #expect(FrameIOMetadata.payload(.unchanged, for: notes) == nil)
        let body = try FrameIOMetadata.body(files: ["F1", "F2"], values: FrameIOMetadata.values(
            [status.id: .set(.ids(["e1"])), notes.id: .unchanged], fields: [status, notes]))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: [String: Any]]
        #expect(object?["data"]?["file_ids"] as? [String] == ["F1", "F2"])
        #expect((object?["data"]?["values"] as? [[String: Any]])?.count == 1)
    }

    @Test("A field the sampled files share shows its value; one they differ on is mixed")
    func common() {
        let samples: [[String: MetadataValue]] = [["s": .ids(["a", "b"]), "r": .number(3)], ["s": .ids(["b", "a"]), "r": .number(4)]]
        #expect(FrameIOMetadata.common(samples, field: "s") == .ids(["a", "b"]))
        #expect(FrameIOMetadata.common(samples, field: "r") == nil)
        #expect(FrameIOMetadata.common(samples, field: "missing") == .empty)
    }
}
