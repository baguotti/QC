import Foundation

/// The theme colours a report is drawn with (the app's Pass / Play / Warn accents), as CSS hex.
public struct ReportColors: Sendable {
    public var positive: String, positiveLight: String
    public var accent: String, accentLight: String
    public var warn: String, warnLight: String

    public init(positive: String, positiveLight: String, accent: String, accentLight: String, warn: String, warnLight: String) {
        self.positive = positive; self.positiveLight = positiveLight
        self.accent = accent; self.accentLight = accentLight
        self.warn = warn; self.warnLight = warnLight
    }

    /// The Muted preset.
    public static let standard = ReportColors(positive: "#2E6F40", positiveLight: "#2E6F40", accent: "#4A7C9D",
                                              accentLight: "#4A7C9D", warn: "#B35454", warnLight: "#B35454")
}

/// The shared look of QCpie's HTML reports: the app's greys, hairlines, corners and type, light and dark.
enum ReportStyle {
    /// `value` if it's a plain hex colour, else `fallback` (theme strings come from a settings file).
    private static func hex(_ value: String, _ fallback: String) -> String {
        let digits = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
        return [3, 6, 8].contains(digits.count) && digits.allSatisfy(\.isHexDigit) ? "#\(digits)" : fallback
    }

    static func css(_ c: ReportColors) -> String {
        let s = ReportColors.standard
        return """
        :root {
            color-scheme: dark;
            --bg: #1D1D1D; --panel: #232323; --subtle: #303030; --header: #292929;
            --line: #383838; --strong: #4D4D4D;
            --text: #E6E6E6; --muted: #949494; --soft: #B8B8B8;
            --positive: \(hex(c.positive, s.positive)); --accent: \(hex(c.accent, s.accent)); --warn: \(hex(c.warn, s.warn));
            --amber: #F5B83D;
            --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            --mono: ui-monospace, "SF Mono", Menlo, monospace;
        }
        [data-theme="light"] {
            color-scheme: light;
            --bg: #F5F5F5; --panel: #FAFAFA; --subtle: #EBEBEB; --header: #F0F0F0;
            --line: #D1D1D1; --strong: #A6A6A6;
            --text: #0F0F0F; --muted: #5C5C5C; --soft: #474747;
            --positive: \(hex(c.positiveLight, s.positiveLight)); --accent: \(hex(c.accentLight, s.accentLight)); --warn: \(hex(c.warnLight, s.warnLight));
            --amber: #B98208;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            background: var(--bg); color: var(--text);
            font: 12px/1.45 var(--font); font-variant-numeric: tabular-nums;
            -webkit-font-smoothing: antialiased; padding: 32px 28px 40px;
        }
        .page { max-width: 1180px; margin: 0 auto; }
        .page.wide { max-width: 1480px; }
        .top {
            display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; flex-wrap: wrap;
            padding-bottom: 16px; margin-bottom: 20px; border-bottom: 1px solid var(--line);
        }
        .brand { font-size: 11px; font-weight: 600; color: var(--muted); margin-bottom: 4px; }
        h1 { font-size: 22px; font-weight: 600; letter-spacing: -0.01em; line-height: 1.15; overflow-wrap: anywhere; }
        .sub { font-size: 12px; color: var(--muted); margin-top: 4px; }
        .actions { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
        .btn {
            font: 500 12px var(--font); color: var(--text); background: var(--panel);
            border: 1px solid var(--line); border-radius: 4px; padding: 5px 11px; cursor: pointer;
        }
        .btn:hover { background: var(--subtle); }
        .btn.primary { background: var(--accent); border-color: var(--accent); color: #FFFFFF; }
        .btn.primary:hover { filter: brightness(1.1); }

        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-bottom: 12px; }
        .stat { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; }
        .stat .num { font-size: 22px; font-weight: 600; line-height: 1.15; }
        .stat .label { font-size: 11px; color: var(--muted); margin-top: 2px; }
        .stat.bad .num { color: var(--warn); }
        .stat.ok .num { color: var(--positive); }
        .facts {
            display: flex; flex-wrap: wrap; gap: 6px 22px; padding: 10px 14px; margin-bottom: 8px;
            background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
        }
        .fact { display: flex; gap: 6px; align-items: center; }
        .fact .k { color: var(--muted); }
        .fact .v { font-weight: 600; }

        .section { display: flex; justify-content: space-between; align-items: baseline; margin: 26px 0 8px; }
        .section h2 { font-size: 13px; font-weight: 600; }
        .section .count { font-size: 11px; color: var(--muted); }
        .card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; overflow: hidden; margin-bottom: 10px; }
        .card.flagged { box-shadow: inset 3px 0 0 var(--warn); }
        .card-head {
            display: flex; justify-content: space-between; align-items: center; gap: 12px;
            padding: 10px 14px; background: var(--header); border-bottom: 1px solid var(--line);
        }
        .card-head .name { font-size: 13px; font-weight: 600; overflow-wrap: anywhere; }
        .card-head .meta { font-size: 11px; color: var(--muted); margin-top: 2px; }
        .scroll { overflow-x: auto; }

        table { width: 100%; border-collapse: collapse; }
        th {
            text-align: left; font-size: 11px; font-weight: 500; color: var(--muted); white-space: nowrap;
            padding: 7px 10px; background: var(--header); border-bottom: 1px solid var(--line);
        }
        td { padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: middle; }
        tbody tr:last-child td { border-bottom: none; }
        tbody tr:not(.folder):hover td { background: color-mix(in srgb, var(--subtle) 55%, transparent); }
        tr.folder td {
            background: var(--bg); color: var(--muted); font-size: 11px; font-weight: 600;
            padding: 14px 10px 6px; overflow-wrap: anywhere;
        }
        tr.mismatch td { background: color-mix(in srgb, var(--warn) 7%, transparent); }
        tr.mismatch td:first-child { box-shadow: inset 3px 0 0 var(--warn); }
        .name-cell { font-weight: 500; overflow-wrap: anywhere; min-width: 220px; }
        .num-cell { color: var(--muted); width: 1%; }
        .mono { font-family: var(--mono); font-size: 11px; }
        .nowrap { white-space: nowrap; }
        .dim { color: var(--muted); }
        .path { color: var(--muted); font-size: 11px; max-width: 160px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .note { display: block; font-size: 11px; color: var(--warn); margin-top: 2px; white-space: normal; }
        .detail { display: block; font-size: 11px; color: var(--muted); margin-top: 2px; white-space: nowrap; }

        .tag {
            display: inline-flex; align-items: center; gap: 5px; padding: 1px 7px; border-radius: 4px;
            font-size: 11px; font-weight: 500; white-space: nowrap; background: var(--subtle); color: var(--soft);
        }
        .tag + .tag { margin-left: 4px; }
        .tag.ok { background: color-mix(in srgb, var(--positive) 20%, transparent); color: color-mix(in srgb, var(--positive) 65%, var(--text)); }
        .tag.bad { background: color-mix(in srgb, var(--warn) 20%, transparent); color: color-mix(in srgb, var(--warn) 70%, var(--text)); }
        .tag.amber { background: color-mix(in srgb, var(--amber) 18%, transparent); color: var(--amber); }
        .tag.big { font-size: 12px; font-weight: 600; padding: 4px 10px; border-radius: 8px; }
        .swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; border: 1px solid var(--strong); vertical-align: -1px; }

        .passed { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); margin-bottom: -1px; }
        .passed .cell {
            display: flex; align-items: center; gap: 8px; padding: 8px 14px; min-width: 0;
            border-bottom: 1px solid var(--line); overflow-wrap: anywhere;
        }
        .dot { flex: none; width: 6px; height: 6px; border-radius: 50%; background: var(--positive); }

        #toast {
            position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
            background: var(--panel); color: var(--text); border: 1px solid var(--strong); border-radius: 8px;
            padding: 8px 14px; font-size: 12px; opacity: 0; transition: opacity 0.2s; pointer-events: none;
        }
        #toast.show { opacity: 1; }
        footer {
            display: flex; justify-content: space-between; gap: 12px; margin-top: 28px; padding-top: 12px;
            border-top: 1px solid var(--line); font-size: 11px; color: var(--muted);
        }
        @media print {
            .actions, #toast { display: none; }
            body { padding: 0; }
            .card, .stat, .facts { break-inside: avoid; }
        }
        """
    }

    /// Theme (follows the Mac, switchable), toast, CSV download and Google Sheets paste.
    static func script(csv: String, tsv: String, csvFileName: String, what: String) -> String {
        """
        <script>
            const csvData = `\(QCUtilities.escapeJSTemplate(csv))`;
            const tsvData = `\(QCUtilities.escapeJSTemplate(tsv))`;
            const csvFilename = `\(QCUtilities.escapeJSTemplate(csvFileName))`;

            function setTheme(theme) {
                document.documentElement.setAttribute('data-theme', theme);
                document.getElementById('theme-text').textContent = theme === 'dark' ? 'Light Mode' : 'Dark Mode';
            }
            setTheme(window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');

            function toggleTheme() {
                setTheme(document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
            }

            let toastTimer;
            function showToast(msg) {
                const t = document.getElementById('toast');
                t.textContent = msg;
                t.classList.add('show');
                clearTimeout(toastTimer);
                toastTimer = setTimeout(() => t.classList.remove('show'), 3500);
            }

            function downloadCSV() {
                const blob = new Blob([csvData], { type: 'text/csv;charset=utf-8;' });
                const link = document.createElement('a');
                link.href = URL.createObjectURL(blob);
                link.download = csvFilename;
                document.body.appendChild(link);
                link.click();
                document.body.removeChild(link);
                showToast('Downloaded ' + csvFilename);
            }

            function openGoogleSheets() {
                navigator.clipboard.writeText(tsvData).then(() => {
                    window.open('https://sheets.new', '_blank');
                    showToast('\(what) copied. Paste it into the new sheet (⌘V).');
                }).catch(() => {
                    downloadCSV();
                    window.open('https://sheets.new', '_blank');
                });
            }
        </script>
        """
    }

    static func actions(extra: String = "") -> String {
        """
        <div class="actions">
            \(extra)
            <button class="btn" onclick="toggleTheme()"><span id="theme-text">Light Mode</span></button>
            <button class="btn" onclick="downloadCSV()">Download CSV</button>
            <button class="btn primary" onclick="openGoogleSheets()">Open in Google Sheets</button>
        </div>
        """
    }

    static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // Gregorian, 24 h on every Mac
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }
}
