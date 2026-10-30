import Foundation

/// A Frame.io metadata field (`GET …/metadata/field_definitions`): Status, Assignee, Rating, Notes, Keywords and the
/// account's custom fields.
struct MetadataField: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// select, select_multi, user_single, user_multi, text, long_text, number, rating, toggle, date.
    let fieldType: String
    let mutable: Bool
    let configuration: Configuration?

    struct Configuration: Decodable, Hashable, Sendable {
        let options: [Option]?
        let maxValue: Int?
        enum CodingKeys: String, CodingKey { case options; case maxValue = "max_value" }
    }

    struct Option: Decodable, Hashable, Sendable {
        let id: String?
        let displayName: String
        let color: String?
        enum CodingKeys: String, CodingKey { case id, color; case displayName = "display_name" }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, mutable
        case fieldType = "field_type"
        case configuration = "field_configuration"
    }

    var options: [Option] { configuration?.options?.filter { $0.id != nil } ?? [] }
    var isUsers: Bool { fieldType == "user_single" || fieldType == "user_multi" }
    var isMulti: Bool { fieldType == "select_multi" || fieldType == "user_multi" }
}

struct MetadataUser: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let email: String?
    var label: String { name?.isEmpty == false ? name! : (email ?? "Unknown") }
}

/// A file's value for a field, as read (`GET …/files/{id}/metadata`).
enum MetadataValue: Equatable, Sendable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
    /// Select options or users: their ids.
    case ids([String])

    /// One field of a file's metadata.
    struct Entry: Decodable {
        let fieldDefinitionID: String
        let mutable: Bool?
        let value: MetadataValue

        enum CodingKeys: String, CodingKey {
            case value, mutable
            case fieldDefinitionID = "field_definition_id"
        }

        private struct Ref: Decodable { let id: String }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fieldDefinitionID = try container.decode(String.self, forKey: .fieldDefinitionID)
            mutable = try container.decodeIfPresent(Bool.self, forKey: .mutable)
            if (try? container.decodeNil(forKey: .value)) ?? true {
                value = .empty
            } else if let refs = try? container.decode([Ref].self, forKey: .value) {
                value = refs.isEmpty ? .empty : .ids(refs.map(\.id))
            } else if let flag = try? container.decode(Bool.self, forKey: .value) {
                value = .bool(flag)
            } else if let number = try? container.decode(Double.self, forKey: .value) {
                value = number == 0 ? .empty : .number(number)
            } else if let text = try? container.decode(String.self, forKey: .value) {
                value = text.isEmpty ? .empty : .text(text)
            } else {
                value = .empty
            }
        }
    }
}

/// What Edit Metadata does with one field.
enum MetadataEdit: Equatable, Sendable {
    case unchanged
    case clear
    case set(MetadataValue)
}

/// Bulk metadata (right-click → Edit Metadata… in the Frame.io browser): the editable fields, what the selected files
/// currently share, and the values to write. Pure, so it's tested directly.
enum FrameIOMetadata {
    /// Field types the editor offers (dates aren't yet: no editable date field to verify the format against).
    static let editableTypes: Set<String> = ["select", "select_multi", "user_single", "user_multi", "text", "long_text",
                                             "number", "rating", "toggle"]
    /// How many files' current values are read when the editor opens (one call each).
    static let sampleLimit = 25
    /// Files per bulk update call (the API allows 10 calls a minute).
    static let batchSize = 100

    /// Status, Assignee and Rating first (Frame.io's own), then the rest by name.
    static func ordered(_ fields: [MetadataField]) -> [MetadataField] {
        let first = ["Status", "Assignee", "Rating"]
        return fields.filter { $0.mutable && editableTypes.contains($0.fieldType) }.sorted { a, b in
            let ia = first.firstIndex(of: a.name) ?? first.count, ib = first.firstIndex(of: b.name) ?? first.count
            return ia != ib ? ia < ib : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The value every sampled file has for a field, `nil` when they differ ("mixed").
    static func common(_ samples: [[String: MetadataValue]], field: String) -> MetadataValue? {
        let values = samples.map { normalised($0[field] ?? .empty) }
        guard let first = values.first else { return .empty }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    /// The JSON value to write, or nil for an unchanged field. Measured formats: option ids, `{id, type}` users, an
    /// integer rating; clearing is `[]`, `""`, `0` or `false` (`null` is refused).
    static func payload(_ edit: MetadataEdit, for field: MetadataField) -> Any? {
        switch edit {
        case .unchanged:
            return nil
        case .clear:
            switch field.fieldType {
            case "select", "select_multi", "user_single", "user_multi": return [Any]()
            case "number", "rating": return 0
            case "toggle": return false
            default: return ""
            }
        case .set(let value):
            switch value {
            case .ids(let ids):
                return field.isUsers ? ids.map { ["id": $0, "type": "user"] } : ids
            case .text(let text): return text
            case .number(let number): return field.fieldType == "rating" ? Int(number) : number
            case .bool(let flag): return flag
            case .empty: return payload(.clear, for: field)
            }
        }
    }

    /// The (field, value) pairs to send, in field order.
    static func values(_ edits: [String: MetadataEdit], fields: [MetadataField]) -> [(field: String, value: Any)] {
        fields.compactMap { field in payload(edits[field.id] ?? .unchanged, for: field).map { (field.id, $0) } }
    }

    /// The bulk update's JSON: `{"data": {"file_ids": […], "values": [{field_definition_id, value}]}}`.
    static func body(files: [String], values: [(field: String, value: Any)]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": [
            "file_ids": files,
            "values": values.map { ["field_definition_id": $0.field, "value": $0.value] },
        ]])
    }

    /// How a value reads in the editor ("Needs Review", "Ana, Tom", "★★★", "On").
    static func describe(_ value: MetadataValue, field: MetadataField, users: [MetadataUser]) -> String {
        switch value {
        case .empty: return "None"
        case .text(let text): return text
        case .bool(let flag): return flag ? "On" : "Off"
        case .number(let number):
            return field.fieldType == "rating" ? String(repeating: "★", count: max(0, Int(number))) : number.formatted()
        case .ids(let ids):
            let names = ids.map { id in
                field.isUsers ? (users.first { $0.id == id }?.label ?? "Someone")
                    : (field.options.first { $0.id == id }?.displayName ?? "Unknown")
            }
            return names.joined(separator: ", ")
        }
    }

    private static func normalised(_ value: MetadataValue) -> MetadataValue {
        if case .ids(let ids) = value { return .ids(ids.sorted()) }
        return value
    }
}
