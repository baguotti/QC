import Foundation

// Writing cells back to the Delivery Plan's Google Sheet. A public link can only be read, so edits go through a small
// Apps Script bound to the sheet and deployed as a web app (runs as its owner, accepts requests carrying a secret
// key QCpie generated). No Google Cloud project or sign-in needed. Google sign-in (Sheets API) can replace it later
// behind the same calls.

/// The deployed script and the key it accepts.
struct PlanWriteLink: Codable, Equatable, Sendable {
    var url: URL
    var token: String
}

/// One cell: 1-based row and column as QCpie saw them, plus the row's code and the column's header so the script can
/// find the cell again if rows were sorted or columns inserted since; `expect` is the text QCpie showed (a cell changed
/// meanwhile isn't overwritten).
struct PlanCellEdit: Codable, Equatable, Sendable {
    let row: Int
    let col: Int
    var code: String? = nil
    var header: String? = nil
    let value: String
    let expect: String
}

struct PlanCellResult: Codable, Equatable, Sendable {
    let row: Int
    let col: Int
    let ok: Bool
    /// The cell's text in the sheet when it wasn't written (changed meanwhile, or the row is gone).
    let current: String?
}

/// QC columns of one deliverable, by code. Nil leaves a column as it is; "" clears it. Written to every tab listing the
/// code (the same deliverable is often listed by placement and by edit).
struct PlanStatusItem: Codable, Equatable, Sendable {
    let code: String
    var status: String? = nil
    var note: String? = nil
    var updated: String? = nil
    var batch: String? = nil
    var frameio: String? = nil
    var uploaded: String? = nil
}

enum PlanWriteError: LocalizedError {
    case notDeployed
    case rejected(String)
    case otherSheet

    var errorDescription: String? {
        switch self {
        case .notDeployed: return "The script didn't answer. Deploy it as a web app with access “Anyone”, then paste its /exec link."
        case .rejected(let message): return message
        case .otherSheet: return "That script belongs to a different spreadsheet."
        }
    }
}

enum AppsScriptWriter {
    /// A fresh secret for a new script.
    static func newToken() -> String {
        (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased().prefix(40).description
    }

    /// The script version this QCpie expects (`ping` reports the deployed one).
    static let scriptVersion = 4

    /// The script to paste into the sheet's Extensions → Apps Script.
    static func script(token: String) -> String {
        """
        // QCpie Delivery Plan, script version \(scriptVersion): lets QCpie read changes and write cells and QC statuses.
        // Deploy → New deployment → Web app · Execute as: Me · Who has access: Anyone. Paste the /exec link into QCpie.
        // Updating: paste the new version over this one, then Deploy → Manage deployments → Edit → Version: New version.
        const TOKEN = '\(token)';
        const VERSION = \(scriptVersion);
        const QC = ['QC Status', 'QC Note', 'QC Updated'];
        // Columns copied to the other tabs listing the same code when edited (QC columns and Batch).
        const MIRRORED = QC.concat(['Batch', 'Frame.io', 'Uploaded']).map(n => n.toLowerCase());
        const TEXT_COLS = ['batch', 'frame.io', 'uploaded'];
        const ITEM_KEYS = { 'qc status': 'status', 'qc note': 'note', 'qc updated': 'updated', 'batch': 'batch', 'frame.io': 'frameio', 'uploaded': 'uploaded' };
        const STATUSES = \(statusesJS);

        function doPost(e) {
          let req;
          try { req = JSON.parse(e.postData.contents); } catch (err) { return out({ ok: false, error: 'Bad request.' }); }
          if (req.token !== TOKEN) return out({ ok: false, error: 'Wrong key: copy the script from QCpie again.' });
          const ss = SpreadsheetApp.getActiveSpreadsheet();
          const props = PropertiesService.getDocumentProperties();
          if (req.action === 'ping') return out({ ok: true, id: ss.getId(), title: ss.getName(), version: VERSION });
          if (req.action === 'changes')
            return out({ ok: true, counter: Number(props.getProperty('counter') || 0), listsSig: cachedListsSignature(ss) });
          if (req.action === 'lists') return out({ ok: true, lists: lists(ss, req.gid) });
          const lock = LockService.getDocumentLock();
          lock.waitLock(20000);
          try {
            let result;
            if (req.action === 'columns') result = ensureColumns(ss, req.names || (req.batch ? ['Batch'] : QC));
            else if (req.action === 'status') result = setStatus(ss, req.items || [], null);
            else if (req.action === 'write') result = writeCells(ss, req.gid, req.cells || []);
            else return out({ ok: false, error: 'Update the script: copy it from QCpie again.' });
            SpreadsheetApp.flush();
            bump(props);
            return out(Object.assign({ ok: true }, result));
          } finally {
            lock.releaseLock();
          }
        }

        // Edits made in Google Sheets: count them (QCpie checks the count every few seconds) and copy QC columns to the
        // other tabs listing the same code.
        function onEdit(e) {
          bump(PropertiesService.getDocumentProperties());
          if (!e || !e.range) return;
          const sheet = e.range.getSheet();
          const h = header(sheet);
          if (!h || !h.code) return;
          const qcCols = MIRRORED.map(n => h.cols[n]).filter(Boolean);
          const r0 = e.range.getRow(), c0 = e.range.getColumn(), nr = e.range.getNumRows(), nc = e.range.getNumColumns();
          if (!qcCols.some(c => c >= c0 && c < c0 + nc) || r0 + nr - 1 <= h.row || nr > 500) return;
          const first = Math.max(r0, h.row + 1);
          // A status set here is dated (QCpie compares it with the files' dates to spot new versions), unless the edit
          // also set QC Updated itself.
          const statusCol = h.cols['qc status'], updatedCol = h.cols['qc updated'];
          const statusEdited = statusCol && statusCol >= c0 && statusCol < c0 + nc;
          const updatedEdited = updatedCol && updatedCol >= c0 && updatedCol < c0 + nc;
          if (statusEdited && updatedCol && !updatedEdited) {
            const who = (e.user && e.user.getEmail && e.user.getEmail()) || 'Sheets';
            const stamp = Utilities.formatDate(new Date(), 'UTC', 'yyyy-MM-dd HH:mm:ss') + ' UTC · ' + who;
            sheet.getRange(first, updatedCol, r0 + nr - first, 1).setValues(Array(r0 + nr - first).fill([stamp]));
          }
          const rows = sheet.getRange(first, 1, r0 + nr - first, sheet.getLastColumn()).getDisplayValues();
          // Only the columns that were edited: copying the others would wipe what the other tabs hold.
          const edited = name => { const c = h.cols[name]; return c && c >= c0 && c < c0 + nc; };
          const items = rows.map(v => ({
            code: v[h.code - 1],
            status: edited('qc status') ? v[h.cols['qc status'] - 1] : null,
            note: edited('qc note') ? v[h.cols['qc note'] - 1] : null,
            updated: (edited('qc updated') || edited('qc status')) && h.cols['qc updated'] ? v[h.cols['qc updated'] - 1] : null,
            batch: edited('batch') ? v[h.cols['batch'] - 1] : null,
            frameio: edited('frame.io') ? v[h.cols['frame.io'] - 1] : null,
            uploaded: edited('uploaded') ? v[h.cols['uploaded'] - 1] : null
          })).filter(i => String(i.code).trim() !== '');
          setStatus(SpreadsheetApp.getActiveSpreadsheet(), items, sheet.getSheetId());
        }

        const norm = v => String(v).replace(/\\s+/g, ' ').trim();
        const key = v => norm(v).toLowerCase();

        function bump(props) {
          props.setProperty('counter', String(Number(props.getProperty('counter') || 0) + 1));
        }

        // The header row: the first of the top 15 with a "Code" cell. Columns by lower-case header text (first wins).
        function header(sheet) {
          const lastCol = sheet.getLastColumn(), lastRow = Math.min(15, sheet.getLastRow());
          if (lastCol < 1 || lastRow < 1) return null;
          const values = sheet.getRange(1, 1, lastRow, lastCol).getDisplayValues();
          for (let r = 0; r < values.length; r++) {
            const cols = {};
            values[r].forEach((v, c) => { const k = key(v); if (k && !cols[k]) cols[k] = c + 1; });
            if (cols['code']) return { row: r + 1, cols: cols, code: cols['code'], lastCol: lastCol };
          }
          return null;
        }

        // Rows by code (lower case) below the header.
        function rowsByCode(sheet, h) {
          const map = {};
          const n = sheet.getLastRow() - h.row;
          if (n < 1) return map;
          sheet.getRange(h.row + 1, h.code, n, 1).getDisplayValues().forEach((v, i) => {
            const k = key(v[0]);
            if (k) (map[k] = map[k] || []).push(h.row + 1 + i);
          });
          return map;
        }

        // Adds columns (at the end) to every tab with a Code column that lacks them: the QC columns (with the status
        // dropdown) or Batch.
        function ensureColumns(ss, names) {
          let added = 0;
          ss.getSheets().forEach(sheet => {
            let h = header(sheet);
            if (!h) return;
            names.forEach(name => {
              if (h.cols[name.toLowerCase()]) return;
              const col = sheet.getLastColumn() + 1;
              if (col > sheet.getMaxColumns()) sheet.insertColumnAfter(sheet.getMaxColumns());
              sheet.getRange(h.row, h.lastCol).copyTo(sheet.getRange(h.row, col), SpreadsheetApp.CopyPasteType.PASTE_FORMAT, false);
              sheet.getRange(h.row, col).setValue(name);
              h = header(sheet);
              added++;
            });
            const batchCol = h.cols['batch'];
            if (batchCol && sheet.getMaxRows() > h.row) sheet.getRange(h.row + 1, batchCol, sheet.getMaxRows() - h.row, 1).setNumberFormat('@');
            const statusCol = h.cols['qc status'];
            const rows = sheet.getMaxRows() - h.row;
            if (statusCol && rows > 0) {
              const rule = SpreadsheetApp.newDataValidation().requireValueInList(STATUSES, true).setAllowInvalid(true).build();
              sheet.getRange(h.row + 1, statusCol, rows, 1).setDataValidation(rule);
            }
          });
          return { added: added };
        }

        // QC columns by code, in every tab listing it (except `skipSheetId`: the tab an edit came from).
        function setStatus(ss, items, skipSheetId) {
          const found = {};
          ss.getSheets().forEach(sheet => {
            if (skipSheetId !== null && sheet.getSheetId() === skipSheetId) return;
            const h = header(sheet);
            if (!h) return;
            const byCode = rowsByCode(sheet, h);
            const groups = {};   // "col|value" → A1 cells: one write per distinct value
            items.forEach(item => {
              const rows = byCode[key(item.code)];
              if (!rows) return;
              found[key(item.code)] = true;
              Object.keys(ITEM_KEYS).map(name => [name, item[ITEM_KEYS[name]]]).forEach(([name, value]) => {
                const col = h.cols[name];
                if (!col || value === null || value === undefined) return;
                rows.forEach(r => {
                  const g = col + '|' + value;
                  (groups[g] = groups[g] || { value: value, cells: [], text: TEXT_COLS.includes(name) }).cells.push(sheet.getRange(r, col).getA1Notation());
                });
              });
            });
            // Batch, Frame.io and Uploaded are written as text, so the sheet keeps exactly what was set (a date-like
            // "2026-11-05 10:42 UTC" mustn't become a date).
            Object.keys(groups).forEach(g => {
              const list = sheet.getRangeList(groups[g].cells);
              if (groups[g].text) list.setNumberFormat('@');
              list.setValue(groups[g].value);
            });
          });
          return { missing: items.map(i => i.code).filter(c => !found[key(c)]) };
        }

        // Cells from the Sheet view. The row is found by code when rows moved, the column by header when columns moved.
        function writeCells(ss, gid, cells) {
          const sheet = ss.getSheets().find(s => String(s.getSheetId()) === String(gid));
          if (!sheet) return { ok: false, error: 'That tab is no longer in the spreadsheet.' };
          const h = header(sheet);
          let byCode = null;
          const results = cells.map(c => {
            let row = c.row, col = c.col;
            if (h && c.code) {
              const here = key(sheet.getRange(row, h.code).getDisplayValue());
              if (here !== key(c.code)) {
                byCode = byCode || rowsByCode(sheet, h);
                const rows = byCode[key(c.code)];
                if (!rows) return { row: c.row, col: c.col, ok: false, current: '' };
                row = rows[0];
              }
            }
            if (h && c.header && h.cols[key(c.header)]) col = h.cols[key(c.header)];
            const range = sheet.getRange(row, col);
            const current = range.getDisplayValue();
            if (c.expect !== undefined && c.expect !== null && norm(current) !== norm(c.expect)) {
              return { row: c.row, col: c.col, ok: false, current: current };
            }
            if (h && TEXT_COLS.some(n => h.cols[n] === col)) range.setNumberFormat('@');
            range.setValue(c.value);
            const name = h ? Object.keys(h.cols).find(k => h.cols[k] === col) : null;
            if (c.code && name && MIRRORED.includes(name)) {
              const item = { code: c.code };
              item[ITEM_KEYS[name]] = c.value;
              setStatus(ss, [item], sheet.getSheetId());
            }
            return { row: c.row, col: c.col, ok: true };
          });
          return { results: results };
        }

        // Dropdown choices by column, from the data validation of the first row under the header. Keyed by the
        // column's header (lower case), else '#' + its 0-based index: QCpie's view leaves hidden columns out, so
        // positions can differ.
        function lists(ss, gid) {
          const sheet = ss.getSheets().find(s => String(s.getSheetId()) === String(gid));
          if (!sheet || sheet.getLastColumn() < 1) return {};
          const h = header(sheet);
          const row = h ? h.row + 1 : 2;
          if (row > sheet.getMaxRows()) return {};
          const names = h ? sheet.getRange(h.row, 1, 1, sheet.getLastColumn()).getDisplayValues()[0] : [];
          const result = {};
          sheet.getRange(row, 1, 1, sheet.getLastColumn()).getDataValidations()[0].forEach((rule, i) => {
            if (!rule) return;
            const type = rule.getCriteriaType(), args = rule.getCriteriaValues();
            let values = null;
            if (type === SpreadsheetApp.DataValidationCriteria.VALUE_IN_LIST) values = args[0];
            else if (type === SpreadsheetApp.DataValidationCriteria.VALUE_IN_RANGE)
              values = args[0].getDisplayValues().reduce((a, r) => a.concat(r), []);
            if (values) values = values.map(String).filter(v => v.trim() !== '');
            if (values && values.length) result[key(names[i] || '') || '#' + i] = values;
          });
          return result;
        }

        // A short fingerprint of every tab's dropdown choices: editing a dropdown doesn't count as an edit, so QCpie
        // compares this on its 10 s check and re-reads the choices only when it changes.
        // QCpie asks every 10 s; reading every tab's validations each time would spend the script's daily run-time
        // quota (90 min on free accounts) on a plan left open all day. Recomputed at most once a minute.
        function cachedListsSignature(ss) {
          const cache = CacheService.getDocumentCache();
          let sig = cache.get('listsSig');
          if (!sig) {
            sig = listsSignature(ss);
            cache.put('listsSig', sig, 60);
          }
          return sig;
        }

        function listsSignature(ss) {
          const all = ss.getSheets().map(s => s.getSheetId() + ':' + JSON.stringify(lists(ss, s.getSheetId()))).join('|');
          return Utilities.base64Encode(Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, all));
        }

        function out(o) {
          return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
        }
        """
    }

    private static var statusesJS: String {
        "[" + PlanQCStatus.allCases.map { "'\($0.title)'" }.joined(separator: ", ") + "]"
    }

    private struct Request: Encodable {
        let token: String
        let action: String
        var gid: String? = nil
        var cells: [PlanCellEdit]? = nil
        var items: [PlanStatusItem]? = nil
        var batch: Bool? = nil
        var names: [String]? = nil
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let id: String?
        let title: String?
        let version: Int?
        let counter: Int?
        let results: [PlanCellResult]?
        let missing: [String]?
        let lists: [String: [String]]?
        let listsSig: String?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Apps Script can take a while (a cold start, a group of 100 rows): a 30 s limit reported writes that landed.
        configuration.timeoutIntervalForRequest = 90
        return URLSession(configuration: configuration)
    }()

    /// Apps Script answers a POST with a redirect to the result, which URLSession follows as a GET.
    private static func send(_ link: PlanWriteLink, _ request: Request) async throws -> Response {
        var urlRequest = URLRequest(url: link.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw PlanWriteError.notDeployed }
        guard decoded.ok else { throw PlanWriteError.rejected(decoded.error ?? "The script refused the edit.") }
        return decoded
    }

    /// Checks the script answers, holds the key and belongs to this spreadsheet; returns its version (1 = the first
    /// script, which had no version).
    @discardableResult
    static func ping(_ link: PlanWriteLink, sheetID: String) async throws -> Int {
        let response = try await send(link, Request(token: link.token, action: "ping"))
        guard response.id == sheetID else { throw PlanWriteError.otherSheet }
        return response.version ?? 1
    }

    /// The script's edit counter: it moves whenever the spreadsheet is edited (in Sheets or through the script).
    static func changeCounter(_ link: PlanWriteLink) async throws -> Int {
        try await changes(link).counter
    }

    /// The edit counter plus a fingerprint of the dropdown choices (nil before script v4).
    static func changes(_ link: PlanWriteLink) async throws -> (counter: Int, listsSig: String?) {
        let response = try await send(link, Request(token: link.token, action: "changes"))
        return (response.counter ?? 0, response.listsSig)
    }

    /// Adds the QC columns (with the status dropdown) to every tab with a Code column that lacks them.
    /// Adds columns to every tab with a Code column that lacks them: the QC columns by default, else `names`.
    static func ensureColumns(_ link: PlanWriteLink, names: [String]? = nil) async throws {
        _ = try await send(link, Request(token: link.token, action: "columns", names: names))
    }

    /// Writes QC columns by code; returns the codes no tab lists.
    static func setStatus(_ link: PlanWriteLink, items: [PlanStatusItem]) async throws -> [String] {
        try await send(link, Request(token: link.token, action: "status", items: items)).missing ?? []
    }

    /// Dropdown choices for one tab (script v4), keyed by the column's header in lower case, else "#" + its index.
    static func lists(_ link: PlanWriteLink, gid: String) async throws -> [String: [String]] {
        try await send(link, Request(token: link.token, action: "lists", gid: gid)).lists ?? [:]
    }

    static func write(_ link: PlanWriteLink, gid: String, cells: [PlanCellEdit]) async throws -> [PlanCellResult] {
        try await send(link, Request(token: link.token, action: "write", gid: gid, cells: cells)).results ?? []
    }

    /// `https://script.google.com/macros/s/<id>/exec` (also accepts `/dev` and `script.googleusercontent.com` links).
    static func parseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host,
              host == "script.google.com" || host.hasSuffix(".googleusercontent.com"),
              url.path.contains("/macros/") else { return nil }
        return url
    }
}
