# QCpie Design Rules

Binding for every UI change. Values live in `Sources/VideoQCApp/Theme.swift`; this file says which to use where.
`python3 scripts/design_lint.py` enforces the mechanical rules (it runs in `scripts/BuildApp.sh`); the rest is on you.
Before adding UI, find the nearest existing equivalent and copy it. Do not invent a new style when one exists.
If two existing styles conflict and neither is clearly the standard, ask the user. Don't pick one yourself.

## Feel

- A quiet pro tool for video QC, styled like Finder and System Settings. Content (video, lists, data) leads; chrome recedes.
- Flat surfaces with hairline dividers and one accent colour. No gradients, no shadows on panels, no decorative icons.
- Motion is felt, never waited on: short, with a slight spring for things that move in and out. Nothing animates for show.
- Every tab works the same way. A panel, chevron, header or shortcut that exists on one tab behaves the same on the others.

## Tokens (never hard-code these)

| Need | Use | Not |
|---|---|---|
| Text | `.font(.ui(size: N, weight:))` with N ∈ 10 caption, 11 small, 12 body, 13 emphasis, 15 title, 22 large title | `.system(size: 12)`, `.caption`, off-scale N |
| Icon / SF Symbol | `.font(.system(size: StudioTheme.scaleFont(N), weight:))` | unscaled sizes |
| Control frame | `StudioTheme.scale(N)` | raw points for hit areas |
| Colour | `StudioPalette(isLightMode)`: `bgMain`, `bgPanel`, `bgSubtle`, `bgCardHeader`, `bgCardSubtle`, `borderLine`, `borderStrong`, `textMain`, `textMuted`, `textSubtle`, `accentBlue` (the user's accent), `positive`, `negative`/`alertRed`, `accentSlotB`, `primaryBtnBg`/`primaryBtnFg` | `Color(red:…)`, `.blue`, `.gray` |
| Corner radius | `Radius.control` (4: buttons, fields, rows, boxes), `Radius.segment` (6: segment in a pill), `Radius.container` (8: pill, card, floating panel) | other numbers |
| Animation | `Motion.sleeve` (side panel in/out), `.page` (switching a drawer's tab), `.snap` (main tab switch, drop into place), `.list` (rows added/removed, expand, scroll-to, notices), `.fade` (modal/popover), `.hover`, `.toast`, `.press` | `.easeInOut(…)`, `.spring(…)`, bare `withAnimation {` |

- `.ui` already scales with Button Size. Never wrap its size in `StudioTheme.scaleFont` (double scaling).
- Raw colours are only for pixels drawn on media (video overlays, scrubber marks, thumbnails). Mark a real exception with `// design-ok: <reason>` at the end of the line.
- Weights: `.semibold` for titles, selected tabs and values; `.medium` for unselected tabs and list names; `.regular` for body. Avoid `.bold` in text (icons may use it).
- Numbers that change (timecode, %, counts): `.monospacedDigit()`, or `SlotText` for animated counters.

## Layout

- A tab is: an optional left panel | content | an optional right drawer. Left panels: padding 22, `bgPanel`, a 1pt `borderLine` on the inner edge, resizable with `PanelResizeHandle` (double-click resets).
- **NEVER BREAK: header bands line up straight across the window.** Every column's header under the tab strip (left panel, center, drawer) is an `HStack` ending in `.headerBand(palette)`: fixed height `StudioTheme.headerBandHeight` (46 at 1×, divider included), `bgCardHeader`, a 1pt bottom divider, horizontal padding 16 (drawers 12). Never size a header with vertical padding, never add a separate divider `Rectangle` under it, and never let content make it taller: the dividers of neighbouring columns must meet at the same y at every Button Size. A misaligned edge between columns is a release blocker.
- Panel section title: `sectionHeader("…")` (12 semibold, `textMuted`), Finder-sidebar style. Spacing between sections 18–22.
- Drawer tab bar: a pill (`bgSubtle` on `Radius.container`, padding 3, segments 25pt tall on `Radius.segment`, 11pt text) then `DrawerCloseButton`, in a `.headerBand(palette, horizontalPadding: 12)`.
- The same goes for any edge shared by neighbouring columns (toolbars under the header, footers): give both sides the same token height, or put the row in one band spanning both.
- Check the result at all three Button Sizes (Settings): bars that run out of room degrade (icons only via `ViewThatFits`, wrap), never clip.

## Components (reuse; extend instead of copying)

- `SleeveToggle(side:isOpen:isLightMode:help:action:)`: the only chevron for showing and hiding a side panel. It is placed in the header band (leading for the left panel, trailing for the drawer) and animates with `Motion.sleeve`.
- `DrawerCloseButton`: the ✕ next to a drawer's tab pill.
- `TransportIconButtonStyle`: icon buttons in headers and transport bars. `ToolHover` (`FrameIOBrowserView.swift`): Finder-style toolbar buttons inside the Frame.io browser.
- `PanelResizeHandle`, `.headerBand`, `.studioBox`, `sectionHeader`, `statBox`, `MediaInfoPanel`, `SidebarModalShell` (settings-style modals).
- Feedback: `showToast` / `onToast` for results ("Copied link", "3 files queued"). An `NSAlert` sheet for anything destructive, where Return cancels and the destructive button names the action. Empty states have a title and one sentence saying what to do (see `MediaInfoPanel`'s `emptyTitle`/`emptyMessage`).

## Behaviour patterns

- **Side panels:** ⌘⇧← toggles the left panel and ⌘⇧→ the right one, on every tab that has them (`KeyboardShortcutRouter` scopes). Each panel has a `SleeveToggle`, slides with `Motion.sleeve` (`.move(edge:)` + `.opacity` in an `HStack`, or animated widths in a `Layout` like `UploadColumns`), and its open state persists in `@AppStorage`. In a custom `Layout` (Upload's `UploadColumns`), slide panels with `.move(edge:)` transitions and let the center take its new width at once: animating widths through `animatableData` re-lays a heavy center (the Frame.io list) every frame and kills the spring. `@AppStorage` writes don't carry `withAnimation`, so animate on the value with `.animation(Motion.sleeve, value:)`. A parent `.animation(_, value:)` overrides a caller's `withAnimation`, so use the same token in both.
- **Hover help:** `.explain("…")` shows the bottom status bar text: a full sentence ending in a period, with the shortcut in brackets, e.g. "Hide Assets & Queue panel (⌘⇧←)." Use `.tip(…)` (tooltip + status bar) for toolbar icons that have no label.
- **Selection:** the accent fill or the 3pt accent bar marks selection, and `alertRed` marks a mismatch. Click, Shift-click (range) and ⌘-click as in Finder. Double-click opens or plays.
- **Copy:** Title Case for buttons, tabs and section titles; sentence case for help, toasts and alerts. Be plain and specific ("Delete 2 items from Frame.io?"); never "Are you sure?". No exclamation marks.
- **Performance is part of the design:** a view that shows high-frequency state (progress, playhead, download %) is its own small view observing only that, so the rest doesn't redraw (see `DrawerTabs`, `UploadSideDrawer`).

## When adding UI, check

1. Does an existing component or tab already do this? Reuse it.
2. All values come from the tokens above, and `python3 scripts/design_lint.py` passes.
3. Light and dark mode, all three Button Sizes, and a non-blue accent. Header dividers line up across all columns with every panel open.
4. Shortcuts and hover help match the sibling controls on the other tabs.
5. If you made something new and reusable, add it to `Theme.swift` and to this file.
