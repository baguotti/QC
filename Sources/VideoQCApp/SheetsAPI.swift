import Foundation

/// The Google Sheets API calls the Delivery Plan uses, as the signed-in user (`GoogleAuth`). Bodies and replies stay
/// `Data` so nothing non-Sendable crosses actors; callers parse them off the main thread.
struct SheetsAPI: Sendable {
    let auth: GoogleAuth
    let session: URLSession

    static let shared = SheetsAPI(auth: .shared, session: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }())

    enum Failure: LocalizedError, Equatable {
        /// 403: the account can't open (or can't edit) the sheet.
        case noAccess(String)
        /// 404: no such spreadsheet (or not shared with this account).
        case notFound
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noAccess(let message): return message.isEmpty ? "Your Google account can't open or edit this sheet." : "Google Sheets refused: \(message)"
            case .notFound: return "That sheet wasn't found, or it isn't shared with your Google account."
            case .http(let code, let message): return "Google Sheets answered \(code)\(message.isEmpty ? "" : ": \(message)")."
            }
        }

        /// Worth trying again later (rate limit, Google's side).
        var isTransient: Bool { if case .http(let code, _) = self { return code == 429 || code >= 500 }; return false }
    }

    struct Tab: Sendable, Equatable {
        let gid: String
        let title: String
        let hidden: Bool
    }

    private static let base = "https://sheets.googleapis.com/v4/spreadsheets/"

    /// `'Tab name'` with quotes doubled: a range for the whole tab.
    static func quoted(_ title: String) -> String { "'" + title.replacingOccurrences(of: "'", with: "''") + "'" }

    // MARK: Calls

    func metadata(_ id: String) async throws -> (title: String, tabs: [Tab]) {
        let data = try await send("GET", id, query: [.init(name: "fields", value: "properties.title,sheets.properties(sheetId,title,index,hidden)")])
        struct Reply: Decodable {
            struct Props: Decodable { let title: String? }
            struct Sheet: Decodable { let properties: SheetProps }
            struct SheetProps: Decodable { let sheetId: Int; let title: String; let index: Int?; let hidden: Bool? }
            let properties: Props?
            let sheets: [Sheet]?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let tabs = (reply.sheets ?? []).sorted { ($0.properties.index ?? 0) < ($1.properties.index ?? 0) }
            .map { Tab(gid: String($0.properties.sheetId), title: $0.properties.title, hidden: $0.properties.hidden ?? false) }
        return (reply.properties?.title ?? "", tabs)
    }

    /// Formatted values of several ranges in one call. The raw reply is returned too: comparing it with the last one
    /// tells whether anything changed without parsing (the 10 s check).
    func values(_ id: String, ranges: [String]) async throws -> Data {
        var query = ranges.map { URLQueryItem(name: "ranges", value: $0) }
        query += [.init(name: "valueRenderOption", value: "FORMATTED_VALUE"), .init(name: "majorDimension", value: "ROWS"),
                  .init(name: "fields", value: "valueRanges.values")]
        return try await send("GET", id + "/values:batchGet", query: query)
    }

    /// Tables from a `values` reply, in the order the ranges were asked (missing trailing cells/rows are absent).
    static func tables(_ data: Data) throws -> [[[String]]] {
        struct Reply: Decodable { struct Range: Decodable { let values: [[String]]? }; let valueRanges: [Range]? }
        return try JSONDecoder().decode(Reply.self, from: data).valueRanges?.map { $0.values ?? [] } ?? []
    }

    /// One tab's layout for the Sheet view: sizes, hidden rows/columns, merges, frozen rows and each cell's format.
    static let cellFormat = "effectiveFormat(backgroundColor,horizontalAlignment,verticalAlignment,wrapStrategy,"
        + "textFormat(foregroundColor,fontSize,bold,italic,underline,strikethrough),borders)"

    func layout(_ id: String, tab title: String) async throws -> Data {
        let format = Self.cellFormat
        let fields = "sheets(properties(gridProperties(frozenRowCount)),merges,data(rowMetadata(pixelSize,hiddenByUser,hiddenByFilter),"
            + "columnMetadata(pixelSize,hiddenByUser),rowData(values(\(format)))))"
        return try await send("GET", id, query: [.init(name: "ranges", value: Self.quoted(title)), .init(name: "fields", value: fields)])
    }

    /// The formats of some rows of a tab (`rows`: 1-based, inclusive ranges): conditional formatting follows the
    /// values, so rows whose values changed are read again (a few KB) instead of the whole layout.
    func rowFormats(_ id: String, tab title: String, rows: [ClosedRange<Int>]) async throws -> Data {
        var query = rows.map { URLQueryItem(name: "ranges", value: "\(Self.quoted(title))!\($0.lowerBound):\($0.upperBound)") }
        query.append(.init(name: "fields", value: "sheets(data(startRow,rowData(values(\(Self.cellFormat)))))"))
        return try await send("GET", id, query: query)
    }

    /// The data validation of one row of a tab (dropdown choices), `row` 1-based.
    func validations(_ id: String, tab title: String, row: Int) async throws -> Data {
        try await send("GET", id, query: [.init(name: "ranges", value: "\(Self.quoted(title))!\(row):\(row)"),
                                           .init(name: "fields", value: "sheets(data(rowData(values(dataValidation))))")])
    }

    /// Writes ranges. `raw`: stored exactly as given (text stays text: "2026-11-05 10:42 UTC" isn't made a date);
    /// otherwise parsed as if typed in Sheets.
    func update(_ id: String, _ data: [(range: String, values: [[String]])], raw: Bool) async throws {
        guard !data.isEmpty else { return }
        let body: [String: Any] = [
            "valueInputOption": raw ? "RAW" : "USER_ENTERED",
            "data": data.map { ["range": $0.range, "majorDimension": "ROWS", "values": $0.values] },
        ]
        _ = try await send("POST", id + "/values:batchUpdate", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// Adds rows after the last row of the table at `range` (new rows inserted: concurrent appends don't overwrite).
    func append(_ id: String, range: String, rows: [[String]]) async throws {
        guard !rows.isEmpty else { return }
        let encoded = range.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? range
        let body = try JSONSerialization.data(withJSONObject: ["majorDimension": "ROWS", "values": rows])
        _ = try await send("POST", id + "/values/\(encoded):append",
                           query: [.init(name: "valueInputOption", value: "RAW"), .init(name: "insertDataOption", value: "INSERT_ROWS")],
                           body: body)
    }

    func clear(_ id: String, ranges: [String]) async throws {
        guard !ranges.isEmpty else { return }
        _ = try await send("POST", id + "/values:batchClear", body: try JSONSerialization.data(withJSONObject: ["ranges": ranges]))
    }

    /// `spreadsheets.batchUpdate` with an encoded `{"requests": […]}` body (atomic: all or nothing). Returns the reply.
    func batchUpdate(_ id: String, body: Data) async throws -> Data {
        try await send("POST", id + ":batchUpdate", body: body)
    }

    /// The spreadsheet's Drive version: it moves on every edit (in Sheets or through the API). A few bytes, where
    /// reading the values is hundreds of KB. Needs the Drive API on in the Cloud project and the Drive metadata scope
    /// (signed in after it was added): otherwise 403, and the plan reads the values every time as before.
    func version(_ id: String) async throws -> String {
        let data = try await send("GET", id, query: [.init(name: "fields", value: "version"), .init(name: "supportsAllDrives", value: "true")],
                                  base: "https://www.googleapis.com/drive/v3/files/")
        struct Reply: Decodable { let version: String? }
        guard let version = try JSONDecoder().decode(Reply.self, from: data).version else { throw Failure.http(0, "no version") }
        return version
    }

    // MARK: Transport

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      base: String = SheetsAPI.base) async throws -> Data {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        // "+" in a query value is read as a space by Google: encode it (tab names, A1 ranges).
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var token = try await auth.accessToken()
        for attempt in 0..<2 {
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Google APIs gzip replies only for clients whose user agent says "gzip" (the 10 s read shrinks ~5×).
            request.setValue("QCpie (gzip)", forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return data
            case 401 where attempt == 0:
                token = try await auth.accessToken(forceRefresh: true)
                continue
            case 401: throw GoogleAuth.Failure.signedOut
            case 403: throw Failure.noAccess(Self.message(data))
            case 404: throw Failure.notFound
            default: throw Failure.http(status, Self.message(data))
            }
        }
        throw GoogleAuth.Failure.signedOut
    }

    static func message(_ data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
    }
}
