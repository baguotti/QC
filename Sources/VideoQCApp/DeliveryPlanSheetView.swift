import SwiftUI
import AppKit

// The Delivery Plan's Sheet view: the linked tab drawn as Google Sheets draws it (widths, heights, colours, borders,
// frozen rows, column letters, row numbers), plus QCpie's status dot per deliverable in the row-number gutter.
// AppKit, one view per area drawing only what's visible: ~1,100 rows × 16 columns stay smooth, and nothing here
// runs unless the panel is on screen and scrolled or its data changes.

/// What QCpie adds to a sheet row: the matched status and whether the row changed since last seen.
struct PlanSheetMark: Equatable {
    var status: PlanState
    var changed: Bool
    /// Plan checks of the row's files: a ring around the dot (green all passed, red one failed).
    var checks: PlanChecksSummary.Result = .notRun
    /// On Frame.io: a small arrow by the dot.
    var upload: PlanUpload = .none
    /// The plan, this Mac and Frame.io disagree: the arrow turns amber (outlined when the row isn't on Frame.io).
    var mismatch = false
}

/// App colours for the chrome around the sheet (gutter, column letters, selection). The cells use the sheet's own.
struct PlanSheetChrome: Equatable {
    var gutter: NSColor
    var line: NSColor
    var text: NSColor
    var accent: NSColor
    var statusColors: [PlanState: NSColor]
    var passed: NSColor
    var failed: NSColor

    @MainActor init(palette: StudioPalette) {
        gutter = NSColor(palette.bgCardHeader)
        line = NSColor(palette.borderLine)
        text = NSColor(palette.textMuted)
        accent = NSColor(palette.accentBlue)
        passed = NSColor(palette.positive)
        failed = NSColor(palette.negative)
        statusColors = Dictionary(uniqueKeysWithValues: PlanState.allCases.map { ($0, NSColor(PlanRowView.color($0, palette))) })
    }
}

struct DeliveryPlanSheetView: NSViewRepresentable {
    let grid: PlanGrid
    /// Sheet lines to show below the frozen rows; nil shows every row.
    let shownLines: Set<Int>?
    let marks: [Int: PlanSheetMark]
    let selectedLines: Set<Int>
    /// When `scrollToken` changes, the sheet scrolls to this line.
    var scrollToLine: Int? = nil
    var scrollToken = 0
    let zoom: Double
    let chrome: PlanSheetChrome
    let onSelect: (_ line: Int, _ clicks: Int) -> Void
    let menu: (_ line: Int) -> NSMenu?
    /// Editing on: double-clicking a cell edits it and `onEdit` gets the change. Off: `onEditUnavailable` (set-up help).
    var canEdit = false
    var onEdit: (_ line: Int, _ column: Int, _ old: String, _ new: String) -> Void = { _, _, _, _ in }
    var onEditUnavailable: () -> Void = {}
    /// The QC Status column: double-clicking it opens `statusMenu` instead of a text field.
    var statusColumn: Int? = nil
    var statusMenu: (_ line: Int) -> NSMenu? = { _ in nil }
    /// Columns (0-based) with a dropdown in the sheet: double-clicking one offers its choices.
    var listColumns: [Int: [String]] = [:]
    /// The sheet's header line: dropdowns start below it (an unfrozen header scrolls with the rows).
    var headerLine: Int? = nil

    func makeNSView(context: Context) -> PlanSheetContainer { PlanSheetContainer() }

    func updateNSView(_ view: PlanSheetContainer, context: Context) {
        view.onSelect = onSelect
        view.menuProvider = menu
        view.canEdit = canEdit
        view.onEdit = onEdit
        view.onEditUnavailable = onEditUnavailable
        view.statusColumn = statusColumn
        view.statusMenu = statusMenu
        if view.listColumns != listColumns { view.listColumns = listColumns }
        if view.headerLine != headerLine { view.headerLine = headerLine }
        view.update(grid: grid, shownLines: shownLines, zoom: zoom, marks: marks, selectedLines: selectedLines, chrome: chrome)
        view.scroll(to: scrollToLine, token: scrollToken)
    }
}

// MARK: - Layout

/// Positions in view points for one grid at one zoom and filter.
struct PlanSheetLayout {
    let zoom: CGFloat
    /// Left edge of each column, plus the right edge of the last.
    let columnX: [CGFloat]
    /// Grid row indices in the header (frozen) and in the scrolling body.
    let frozen: [Int]
    let body: [Int]
    /// Top of each body row, plus the bottom of the last.
    let bodyY: [CGFloat]
    let frozenHeight: CGFloat

    static let letterBar: CGFloat = 20
    static let gutterWidth: CGFloat = 58

    init(grid: PlanGrid, shownLines: Set<Int>?, zoom: CGFloat) {
        self.zoom = zoom
        var x: [CGFloat] = [0]
        for w in grid.columnWidths { x.append(x.last! + (w * zoom).rounded()) }
        columnX = x
        let frozenCount = min(grid.frozenRows, grid.rows.count)
        frozen = Array(0..<frozenCount)
        body = (frozenCount..<grid.rows.count).filter { shownLines?.contains(grid.rows[$0].line) ?? true }
        frozenHeight = frozen.reduce(0) { $0 + (grid.rows[$1].height * zoom).rounded() }
        var y: [CGFloat] = [0]
        for index in body { y.append(y.last! + (grid.rows[index].height * zoom).rounded()) }
        bodyY = y
    }

    var width: CGFloat { columnX.last ?? 0 }
    var bodyHeight: CGFloat { bodyY.last ?? 0 }

    /// The body row at a y in body coordinates.
    func bodyRow(at y: CGFloat) -> Int? {
        guard y >= 0, y < bodyHeight else { return nil }
        var lo = 0, hi = body.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if bodyY[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The column at an x (0 = first column).
    func column(at x: CGFloat) -> Int? {
        guard x >= 0, x < width, columnX.count > 1 else { return nil }
        var lo = 0, hi = columnX.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if columnX[mid] <= x { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Body rows meeting a y range.
    func bodyRows(from top: CGFloat, to bottom: CGFloat) -> Range<Int> {
        guard !body.isEmpty, let first = bodyRow(at: max(0, top)) else { return 0..<0 }
        var last = bodyRow(at: min(bottom, bodyHeight - 0.5)) ?? body.count - 1
        last = max(first, last)
        return first..<(last + 1)
    }
}

// MARK: - Painting

/// Draws sheet rows. Fonts and paragraph styles are cached per size/weight.
final class PlanSheetPainter {
    private var fonts: [String: NSFont] = [:]
    /// Columns drawn with Sheets' dropdown chevron (body rows only).
    var dropdownColumns: Set<Int> = []
    private static let gridline = NSColor(white: 0, alpha: 0.15)   // design-ok: Google Sheets' own gridline colour

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,   // design-ok: the sheet's own colours
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    func font(_ style: PlanGridStyle, zoom: CGFloat) -> NSFont {
        // CSS pt → px (×4/3); a CSS px is a point.
        let size = (style.fontSize * 4 / 3 * zoom * 2).rounded() / 2
        let key = "\(size)|\(style.bold)|\(style.italic)"
        if let font = fonts[key] { return font }
        var font = NSFont(name: "Helvetica Neue", size: size) ?? NSFont.systemFont(ofSize: size)
        if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        fonts[key] = font
        return font
    }

    private var paragraphs: [Int: NSParagraphStyle] = [:]

    /// Six possible styles (alignment × wrap), made once instead of per cell per draw.
    private func paragraphStyle(_ style: PlanGridStyle) -> NSParagraphStyle {
        let key = style.align.rawValue * 2 + (style.wrap ? 1 : 0)
        if let cached = paragraphs[key] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.align == .center ? .center : style.align == .right ? .right : .left
        paragraph.lineBreakMode = style.wrap ? .byWordWrapping : .byClipping
        paragraphs[key] = paragraph
        return paragraph
    }

    /// One sheet row with its top-left at `origin`; `clip` limits the columns worth drawing.
    func draw(_ grid: PlanGrid, row index: Int, origin: CGPoint, height: CGFloat, layout: PlanSheetLayout, clip: CGRect,
              dropdowns: Bool = false) {
        let row = grid.rows[index]
        let x = layout.columnX
        let zoom = layout.zoom
        func frame(_ cell: PlanGridCell) -> CGRect {
            let left = x[min(cell.column, x.count - 1)]
            let right = x[min(cell.column + cell.span, x.count - 1)]
            return CGRect(x: origin.x + left, y: origin.y, width: right - left, height: height)
        }
        let rowRect = CGRect(x: origin.x, y: origin.y, width: layout.width, height: height)
        // Background for cells the HTML doesn't list (past the last cell): white.
        NSColor.white.setFill()   // design-ok: a sheet's default cell colour
        rowRect.intersection(clip).fill()

        let cells = row.cells
        for cell in cells {
            let rect = frame(cell)
            guard rect.maxX >= clip.minX, rect.minX <= clip.maxX else { continue }
            let style = grid.styles[min(cell.style, grid.styles.count - 1)]
            (style.background.map(Self.color) ?? .white).setFill()   // design-ok: the sheet's own colours
            rect.fill()
            Self.gridline.setFill()
            CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
            CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        }
        // Explicit borders over the gridlines.
        for cell in cells {
            let rect = frame(cell)
            guard rect.maxX >= clip.minX, rect.minX <= clip.maxX else { continue }
            let style = grid.styles[min(cell.style, grid.styles.count - 1)]
            func edge(_ border: PlanGridBorder?, _ make: (CGFloat) -> CGRect) {
                guard let border else { return }
                Self.color(border.color).setFill()
                make(max(1, (border.width * zoom).rounded())).fill()
            }
            edge(style.top) { CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: $0) }
            edge(style.bottom) { CGRect(x: rect.minX, y: rect.maxY - $0, width: rect.width, height: $0) }
            edge(style.left) { CGRect(x: rect.minX, y: rect.minY, width: $0, height: rect.height) }
            edge(style.right) { CGRect(x: rect.maxX - $0, y: rect.minY, width: $0, height: rect.height) }
        }
        // Text last, so unwrapped text can run over empty cells to its right as in Sheets.
        let padX = 3 * zoom, padY = 2 * zoom
        for (i, cell) in cells.enumerated() where !cell.text.isEmpty {
            var rect = frame(cell)
            let style = grid.styles[min(cell.style, grid.styles.count - 1)]
            if !style.wrap, style.align == .left {
                var j = i + 1
                while j < cells.count, cells[j].text.isEmpty { rect.size.width = frame(cells[j]).maxX - rect.minX; j += 1 }
                if j == cells.count { rect.size.width = max(rect.width, origin.x + layout.width - rect.minX) }
            }
            guard rect.maxX >= clip.minX, rect.minX <= clip.maxX else { continue }
            let paragraph = paragraphStyle(style)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(style, zoom: zoom),
                .foregroundColor: style.color.map(Self.color) ?? .black,   // design-ok: the sheet's own colours
                .paragraphStyle: paragraph,
            ]
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let text = NSAttributedString(string: style.wrap ? cell.text : cell.text.replacingOccurrences(of: "\n", with: " "),
                                          attributes: attributes)
            let inner = rect.insetBy(dx: padX, dy: padY)
            guard inner.width > 0, inner.height > 0 else { continue }
            let measured = text.boundingRect(with: CGSize(width: style.wrap ? inner.width : 10_000, height: 10_000),
                                             options: [.usesLineFragmentOrigin]).height.rounded(.up)
            let textHeight = measured
            let y: CGFloat
            switch style.valign {
            case .top: y = inner.minY
            case .middle: y = inner.midY - textHeight / 2
            case .bottom: y = inner.maxY - textHeight
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            // Unwrapped text gets a wide box so it never breaks; the box is placed so its alignment lands on the cell's
            // (a left-anchored 10,000 pt box put centred text 5,000 pt to the right, outside the cell).
            let box: CGRect
            if style.wrap {
                box = CGRect(x: inner.minX, y: y, width: inner.width, height: textHeight)
            } else {
                let wide: CGFloat = 10_000
                let left: CGFloat
                switch style.align {
                case .left: left = inner.minX
                case .center: left = inner.midX - wide / 2
                case .right: left = inner.maxX - wide
                }
                box = CGRect(x: left, y: y, width: wide, height: textHeight)
            }
            text.draw(with: box, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
        if dropdowns, !dropdownColumns.isEmpty { drawChevrons(origin: origin, height: height, layout: layout, clip: clip) }
    }

    /// Sheets' ▾ at the right of each dropdown cell.
    private func drawChevrons(origin: CGPoint, height: CGFloat, layout: PlanSheetLayout, clip: CGRect) {
        let x = layout.columnX
        let size = 4 * layout.zoom
        NSColor(white: 0.45, alpha: 1).setFill()   // design-ok: Sheets' own chevron grey
        for column in dropdownColumns where column + 1 < x.count {
            let right = origin.x + x[column + 1] - 6 * layout.zoom
            guard right >= clip.minX, right - size * 2 <= clip.maxX else { continue }
            let midY = origin.y + height / 2
            let path = NSBezierPath()
            path.move(to: CGPoint(x: right - size * 2, y: midY - size / 2))
            path.line(to: CGPoint(x: right, y: midY - size / 2))
            path.line(to: CGPoint(x: right - size, y: midY + size / 2))
            path.close()
            path.fill()
        }
    }
}

// MARK: - Views

final class PlanSheetContainer: NSView, NSTextFieldDelegate {
    var onSelect: ((Int, Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    var canEdit = false
    var onEdit: ((Int, Int, String, String) -> Void)?
    var onEditUnavailable: (() -> Void)?
    var statusColumn: Int?
    var statusMenu: ((Int) -> NSMenu?)?
    var listColumns: [Int: [String]] = [:] {
        didSet { painter.dropdownColumns = Set(listColumns.keys); body.needsDisplay = true }
    }
    var headerLine: Int? {
        didSet { body.needsDisplay = true }
    }
    private var editor: NSTextField?
    private var editing: (line: Int, column: Int, old: String)?

    private(set) var grid: PlanGrid?
    private(set) var sheetLayout: PlanSheetLayout?
    private(set) var marks: [Int: PlanSheetMark] = [:]
    private(set) var selectedLines: Set<Int> = []
    private var scrollToken = 0
    private(set) var chrome: PlanSheetChrome?
    private var shownLines: Set<Int>?
    private var zoom: Double = 1
    let painter = PlanSheetPainter()

    private let scroll = NSScrollView()
    private let body = PlanSheetBody()
    private let header = PlanSheetHeader()
    private let gutter = PlanSheetGutter()
    private let corner = PlanSheetCorner()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        // Since macOS 14 views don't clip their drawing by default: unclipped, the gutter painted over the whole window.
        clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = body
        scroll.contentView.postsBoundsChangedNotifications = true
        for view in [body, header, gutter, corner] as [PlanSheetPart] {
            view.container = self
            view.clipsToBounds = true
        }
        addSubview(scroll)
        addSubview(header)
        addSubview(gutter)
        addSubview(corner)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    var scrollOffset: CGPoint { scroll.contentView.bounds.origin }

    @objc private func scrolled() {
        header.needsDisplay = true
        gutter.needsDisplay = true
    }

    func update(grid: PlanGrid, shownLines: Set<Int>?, zoom: Double, marks: [Int: PlanSheetMark], selectedLines: Set<Int>,
                chrome: PlanSheetChrome) {
        let relayout = grid != self.grid || shownLines != self.shownLines || zoom != self.zoom || sheetLayout == nil
        let redraw = relayout || marks != self.marks || selectedLines != self.selectedLines || chrome != self.chrome
        self.grid = grid
        self.shownLines = shownLines
        self.zoom = zoom
        self.marks = marks
        self.selectedLines = selectedLines
        self.chrome = chrome
        if relayout {
            sheetLayout = PlanSheetLayout(grid: grid, shownLines: shownLines, zoom: zoom)
            needsLayout = true
            repositionEditor()
        }
        if redraw { for view in [body, header, gutter, corner] as [NSView] { view.needsDisplay = true } }
    }

    override func layout() {
        super.layout()
        guard let layout = sheetLayout else { return }
        let headerHeight = PlanSheetLayout.letterBar + layout.frozenHeight
        let g = PlanSheetLayout.gutterWidth
        corner.frame = CGRect(x: 0, y: 0, width: g, height: headerHeight)
        header.frame = CGRect(x: g, y: 0, width: max(0, bounds.width - g), height: headerHeight)
        gutter.frame = CGRect(x: 0, y: headerHeight, width: g, height: max(0, bounds.height - headerHeight))
        scroll.frame = CGRect(x: g, y: headerHeight, width: max(0, bounds.width - g), height: max(0, bounds.height - headerHeight))
        body.frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.bodyHeight)
    }

    /// The sheet line under a y in body coordinates.
    func line(atBodyY y: CGFloat) -> Int? {
        guard let layout = sheetLayout, let grid, let index = layout.bodyRow(at: y) else { return nil }
        return grid.rows[layout.body[index]].line
    }

    func forwardScroll(_ event: NSEvent) { scroll.scrollWheel(with: event) }

    /// Centres a line when the token changes (Inspect selected its file), keeping the horizontal position.
    func scroll(to line: Int?, token: Int) {
        guard token != scrollToken else { return }
        scrollToken = token
        guard let line, let layout = sheetLayout, let grid,
              let i = layout.body.firstIndex(where: { grid.rows[$0].line == line }) else { return }
        layoutSubtreeIfNeeded()
        let visible = scroll.contentView.bounds
        let rowMid = (layout.bodyY[i] + layout.bodyY[i + 1]) / 2
        guard rowMid < visible.minY + 20 || rowMid > visible.maxY - 20 else { return }
        let y = min(max(0, rowMid - visible.height / 2), max(0, layout.bodyHeight - visible.height))
        scroll.contentView.scroll(to: CGPoint(x: visible.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Editing

    /// Opens an editor over the cell at a point in body coordinates.
    func beginEdit(atBody point: CGPoint) {
        guard let layout = sheetLayout, let row = layout.bodyRow(at: point.y), let column = layout.column(at: point.x) else { return }
        beginEdit(bodyRow: row, column: column)
    }

    private func beginEdit(bodyRow row: Int, column: Int) {
        guard let layout = sheetLayout, let grid else { return }
        guard canEdit else { onEditUnavailable?(); return }
        let line = grid.rows[layout.body[row]].line
        if column == statusColumn, let menu = statusMenu?(line) {
            endEditor(commit: true)
            onSelect?(line, 1)
            let x = layout.columnX[column], y = layout.bodyY[row + 1]
            menu.popUp(positioning: nil, at: CGPoint(x: x, y: y), in: body)
            return
        }
        if let options = listColumns[column], line > (headerLine ?? 0) {
            endEditor(commit: true)
            onSelect?(line, 1)
            let current = grid.cell(line: line, column: column).map { grid.rows[$0.0].cells[$0.1].text } ?? ""
            let menu = NSMenu()
            for option in options {
                menu.addItem(option) { [weak self] in
                    if PlanGrid.normalized(option) != PlanGrid.normalized(current) { self?.onEdit?(line, column, current, option) }
                }
                if PlanGrid.normalized(option) == PlanGrid.normalized(current) { menu.items.last?.state = .on }
            }
            if !current.isEmpty {
                menu.addItem(.separator())
                menu.addItem("Clear") { [weak self] in self?.onEdit?(line, column, current, "") }
            }
            let x = layout.columnX[column], y = layout.bodyY[row + 1]
            menu.popUp(positioning: nil, at: CGPoint(x: x, y: y), in: body)
            return
        }
        guard let (gridRow, index) = grid.cell(line: line, column: column) else { return }
        let cell = grid.rows[gridRow].cells[index]
        let style = grid.styles[min(cell.style, grid.styles.count - 1)]
        let left = layout.columnX[cell.column], right = layout.columnX[min(cell.column + cell.span, layout.columnX.count - 1)]
        let rowHeight = layout.bodyY[row + 1] - layout.bodyY[row]
        let field = NSTextField(string: cell.text)
        field.font = painter.font(style, zoom: layout.zoom)
        field.textColor = .black   // design-ok: editing inside the sheet's own white cells
        field.backgroundColor = .white   // design-ok: as above
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderColor = chrome?.accent.cgColor
        field.layer?.borderWidth = 2
        field.frame = CGRect(x: left, y: layout.bodyY[row], width: max(right - left, 120), height: max(rowHeight, 24))
        endEditor(commit: true)
        onSelect?(line, 1)
        editing = (line, cell.column, cell.text)
        editor = field
        body.addSubview(field)
        body.scrollToVisible(field.frame)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The sheet re-laid out while a cell is being edited (a background read, zoom, a filter): the editor follows its
    /// cell, or saves and closes when the row is no longer shown.
    private func repositionEditor() {
        guard let field = editor, let editing, let layout = sheetLayout, let grid else { return }
        guard let row = layout.body.firstIndex(where: { grid.rows[$0].line == editing.line }),
              let (gridRow, index) = grid.cell(line: editing.line, column: editing.column) else {
            endEditor(commit: true)
            return
        }
        let cell = grid.rows[gridRow].cells[index]
        let left = layout.columnX[cell.column], right = layout.columnX[min(cell.column + cell.span, layout.columnX.count - 1)]
        field.frame = CGRect(x: left, y: layout.bodyY[row], width: max(right - left, 120),
                             height: max(layout.bodyY[row + 1] - layout.bodyY[row], 24))
    }

    private func endEditor(commit: Bool) {
        guard let field = editor, let editing else { return }
        self.editor = nil
        self.editing = nil
        field.delegate = nil
        field.removeFromSuperview()
        if commit, field.stringValue != editing.old {
            onEdit?(editing.line, editing.column, editing.old, field.stringValue)
        }
    }

    /// Return or clicking away saves, Esc cancels, Tab saves and edits the next cell. (In the main window the shortcut
    /// router takes Return/Esc and only ends editing, so Esc is read from the current event.)
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editing, let layout = sheetLayout, let grid else { return }
        let cancelled = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap { NSTextMovement(rawValue: $0) }
        endEditor(commit: !cancelled)
        if movement == .tab, let row = layout.body.firstIndex(where: { grid.rows[$0].line == editing.line }),
           let (gridRow, index) = grid.cell(line: editing.line, column: editing.column) {
            let next = grid.rows[gridRow].cells[index].column + grid.rows[gridRow].cells[index].span
            if next < layout.columnX.count - 1 {
                DispatchQueue.main.async { self.beginEdit(bodyRow: row, column: next) }
            }
        }
        // Back to the sheet only when a key ended the edit: a click elsewhere (the search or note field) keeps its focus.
        if NSApp.currentEvent?.type == .keyDown { window?.makeFirstResponder(body) }
    }
}

/// Shared plumbing of the four areas.
class PlanSheetPart: NSView {
    weak var container: PlanSheetContainer?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Body y for a point in this view (nil outside the rows).
    func bodyY(_ point: CGPoint) -> CGFloat? { nil }

    override func mouseDown(with event: NSEvent) {
        guard let container, let y = bodyY(convert(event.locationInWindow, from: nil)),
              let line = container.line(atBodyY: y) else { return }
        container.onSelect?(line, event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let container, let y = bodyY(convert(event.locationInWindow, from: nil)),
              let line = container.line(atBodyY: y) else { return nil }
        container.onSelect?(line, 1)
        return container.menuProvider?(line)
    }
}

/// The scrolling cells.
final class PlanSheetBody: PlanSheetPart {
    override func bodyY(_ point: CGPoint) -> CGFloat? { point.y }
    override var acceptsFirstResponder: Bool { true }

    /// Click selects the row; double-click edits the cell (playing is the row number's double-click).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            // Editing set up: edit the cell. Otherwise play the row's file (the set-up is in the ••• menu, not a
            // sheet popping up on every double-click).
            if container?.canEdit == true {
                container?.beginEdit(atBody: point)
            } else if let container, let line = container.line(atBodyY: point.y) {
                container.onSelect?(line, 2)
            }
            return
        }
        guard let container, let line = container.line(atBodyY: point.y) else { return }
        container.onSelect?(line, 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let container, let grid = container.grid, let layout = container.sheetLayout else { return }
        let dirtyRect = dirtyRect.intersection(bounds)
        NSColor.white.setFill()   // design-ok: a sheet's default cell colour
        dirtyRect.fill()
        for i in layout.bodyRows(from: dirtyRect.minY, to: dirtyRect.maxY) {
            let y = layout.bodyY[i]
            container.painter.draw(grid, row: layout.body[i], origin: CGPoint(x: 0, y: y),
                                   height: layout.bodyY[i + 1] - y, layout: layout, clip: dirtyRect,
                                   dropdowns: grid.rows[layout.body[i]].line > (container.headerLine ?? 0))
        }
        if let chrome = container.chrome, !container.selectedLines.isEmpty {
          for i in layout.bodyRows(from: dirtyRect.minY, to: dirtyRect.maxY) where container.selectedLines.contains(grid.rows[layout.body[i]].line) {
            let rect = CGRect(x: 0, y: layout.bodyY[i], width: layout.width, height: layout.bodyY[i + 1] - layout.bodyY[i])
            chrome.accent.withAlphaComponent(0.12).setFill()
            rect.fill(using: .sourceOver)
            chrome.accent.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
          }
        }
    }
}

/// Column letters and the frozen rows; follows the body sideways.
final class PlanSheetHeader: PlanSheetPart {
    override func scrollWheel(with event: NSEvent) { container?.forwardScroll(event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let container, let grid = container.grid, let layout = container.sheetLayout, let chrome = container.chrome else { return }
        let dx = -container.scrollOffset.x
        chrome.gutter.setFill()
        bounds.fill()
        let letterFont = NSFont.systemFont(ofSize: StudioTheme.scaleFont(10), weight: .medium)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        for c in 0..<max(0, layout.columnX.count - 1) {
            let rect = CGRect(x: layout.columnX[c] + dx, y: 0, width: layout.columnX[c + 1] - layout.columnX[c], height: PlanSheetLayout.letterBar)
            guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
            let label = NSAttributedString(string: PlanGrid.columnName(c), attributes: [.font: letterFont, .foregroundColor: chrome.text, .paragraphStyle: centered])
            let h = label.size().height
            label.draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h))
            chrome.line.setFill()
            CGRect(x: rect.maxX - 1, y: 0, width: 1, height: rect.height).fill()
        }
        chrome.line.setFill()
        CGRect(x: 0, y: PlanSheetLayout.letterBar - 1, width: bounds.width, height: 1).fill()
        var y = PlanSheetLayout.letterBar
        let clip = CGRect(x: -dx, y: 0, width: bounds.width, height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSAffineTransform().then { $0.translateX(by: dx, yBy: 0) }.concat()
        for index in layout.frozen {
            let h = (grid.rows[index].height * layout.zoom).rounded()
            container.painter.draw(grid, row: index, origin: CGPoint(x: 0, y: y), height: h, layout: layout, clip: clip)
            y += h
        }
        NSGraphicsContext.restoreGraphicsState()
        // The frozen-row divider Sheets draws.
        chrome.line.setFill()
        CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
    }
}

/// Row numbers with QCpie's status per deliverable; follows the body up and down.
final class PlanSheetGutter: PlanSheetPart {
    override func bodyY(_ point: CGPoint) -> CGFloat? { point.y + (container?.scrollOffset.y ?? 0) }
    override func scrollWheel(with event: NSEvent) { container?.forwardScroll(event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let container, let grid = container.grid, let layout = container.sheetLayout, let chrome = container.chrome else { return }
        let dirtyRect = dirtyRect.intersection(bounds)
        chrome.gutter.setFill()
        dirtyRect.fill()
        let dy = container.scrollOffset.y
        let rows = layout.bodyRows(from: dirtyRect.minY + dy, to: dirtyRect.maxY + dy)
        for i in rows {
            let line = grid.rows[layout.body[i]].line
            let rect = CGRect(x: 0, y: layout.bodyY[i] - dy, width: bounds.width, height: layout.bodyY[i + 1] - layout.bodyY[i])
            Self.drawNumber(line, mark: container.marks[line], selected: container.selectedLines.contains(line), in: rect, chrome: chrome)
        }
        chrome.line.setFill()
        CGRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    static func drawNumber(_ line: Int, mark: PlanSheetMark?, selected: Bool, in rect: CGRect, chrome: PlanSheetChrome) {
        if selected {
            chrome.accent.withAlphaComponent(0.2).setFill()
            rect.fill()
        }
        if mark?.changed == true {
            chrome.accent.setFill()
            CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
        }
        if let mark, let color = chrome.statusColors[mark.status] {
            color.setFill()
            let d: CGFloat = 7
            NSBezierPath(ovalIn: CGRect(x: rect.minX + 8, y: rect.midY - d / 2, width: d, height: d)).fill()
            let ring: NSColor? = mark.checks == .passed ? chrome.passed : mark.checks == .failed ? chrome.failed
                : mark.checks == .partial ? chrome.text : nil
            if let ring {
                ring.setStroke()
                let path = NSBezierPath(ovalIn: CGRect(x: rect.minX + 6, y: rect.midY - d / 2 - 2, width: d + 4, height: d + 4))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
        if let mark, mark.upload != .none || mark.mismatch {
            let color = mark.mismatch ? chrome.statusColors[.check] ?? chrome.accent : chrome.accent
            let s: CGFloat = 3, x = rect.minX + 19, y = rect.midY
            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: x, y: y - s))
            arrow.line(to: CGPoint(x: x + s, y: y + 1))
            arrow.line(to: CGPoint(x: x - s, y: y + 1))
            arrow.close()
            color.setFill(); color.setStroke()
            if mark.upload != .none { arrow.fill() } else { arrow.lineWidth = 1; arrow.stroke() }
            CGRect(x: x - 0.75, y: y + 1, width: 1.5, height: s).fill()
        }
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let label = NSAttributedString(string: "\(line)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: StudioTheme.scaleFont(10), weight: selected ? .semibold : .regular),
            .foregroundColor: chrome.text, .paragraphStyle: right])
        let h = label.size().height
        label.draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width - 7, height: h))
        chrome.line.setFill()
        CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
    }
}

/// Top-left: the blank corner and the frozen rows' numbers.
final class PlanSheetCorner: PlanSheetPart {
    override func draw(_ dirtyRect: NSRect) {
        guard let container, let grid = container.grid, let layout = container.sheetLayout, let chrome = container.chrome else { return }
        chrome.gutter.setFill()
        bounds.fill()
        var y = PlanSheetLayout.letterBar
        for index in layout.frozen {
            let h = (grid.rows[index].height * layout.zoom).rounded()
            PlanSheetGutter.drawNumber(grid.rows[index].line, mark: nil, selected: false,
                                       in: CGRect(x: 0, y: y, width: bounds.width, height: h), chrome: chrome)
            y += h
        }
        chrome.line.setFill()
        CGRect(x: 0, y: PlanSheetLayout.letterBar - 1, width: bounds.width, height: 1).fill()
        CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
    }
}

private extension NSAffineTransform {
    func then(_ body: (NSAffineTransform) -> Void) -> NSAffineTransform { body(self); return self }
}

extension NSMenu {
    /// A menu item running a closure.
    func addItem(_ title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(PlanMenuAction.run), keyEquivalent: "")
        let target = PlanMenuAction(action)
        item.target = target
        item.representedObject = target   // keeps the target alive with the item
        addItem(item)
    }
}

final class PlanMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
