# QCpie Timecoded Notes & Feedback Architecture
## Feasibility Study, Technical Evaluation & Recommendation

**Target Software:** QCpie / LineFinder 5000  
**Context:** Production Company Internal Review & QC Workflow  
**Target Capability:** Frame-accurate, timecoded text notes (Frame.io style) shared across colleagues with zero server overhead and minimal failure points.

---

## 1. Executive Summary & Direct Answers

### Is this too ambitious?
**No. It is well within scope and remarkably straightforward to achieve.**  
QCpie already contains 60% of the foundational architecture:
- Frame-accurate SMPTE timecode generation (`TimecodeFormatter`).
- A functional timeline scrubber with interactive marker rendering (`PlayerTimelineMarker` in `TimelineScrubberView.swift`).
- Precise frame-seeking and playhead navigation engines (`PlayerEngine.swift`).

### Would you recommend embedding into the video file itself?
**We strongly recommend AGAINST rewriting the video container itself.**  
Modifying a video container binary (e.g. injecting atoms into `.mov` or `.mp4` files) in a professional post-production environment introduces severe liabilities:
1. **File Corruption Risk:** If an app crashes or a network drop occurs mid-write on a 40GB ProRes master, the video deliverable can be rendered unreadable.
2. **Network/Storage Bottlenecks:** On shared 10GbE NAS/SAN storage (SMB/NFS) or cloud-synced folders (LucidLink, Dropbox, Google Drive), writing metadata into the file often requires re-wrapping/muxing the entire file or locks the file from being opened by NLEs (Premiere, DaVinci Resolve, Avid).
3. **Checksum & QC Invalidation:** In broadcast and post-production, files often have strict MD5/SHA checksums and modified timestamps. Altering the video file invalidates delivery manifests and archive verifications.

### The Recommended Solution: The "Sidecar Marker File" (`.qcnotes`)
The industry standard used by Adobe (XMP), DaVinci Resolve (EDL/DRT), Avid (Marker TXT), and subtitle streams (SRT/VTT) is the **Sidecar File**.
- When `Client_Commercial_v04.mov` is commented on, QCpie writes a tiny (~2 KB) text/JSON file next to it:  
  `Client_Commercial_v04.mov.qcnotes` (or `Client_Commercial_v04.qcnotes.json`).
- When any colleague in the production company opens `Client_Commercial_v04.mov` in QCpie, the player automatically detects the companion `.qcnotes` file in the same folder and instantly loads all timecoded notes onto the timeline and notes inspector.
- **Zero failure points:** The video file remains 100% read-only and pristine. Notes save in `< 1 millisecond`. Syncing across Dropbox, LucidLink, or a shared server happens instantaneously.

---

## 2. Comparative Evaluation of Storage Strategies

| Criteria | 1. Video Atom Injection (Embedding) | 2. macOS Extended Attributes (`xattr`) | 3. Central Database / Server | 4. Sidecar File (`.qcnotes`) **[RECOMMENDED]** |
| :--- | :--- | :--- | :--- | :--- |
| **Safety / Risk to Media** | 🔴 **High** (Can corrupt file or lock playback) | 🟢 **Zero** (Media untouched) | 🟢 **Zero** (Media untouched) | 🟢 **Zero** (Media untouched) |
| **Post-Production Compatibility** | 🔴 Breaks MD5 checksums & modified dates | 🟢 Media untouched | 🟢 Media untouched | 🟢 Media untouched |
| **Cross-Platform / Sync Reliability**| 🟡 Fragile across active NLE projects | 🔴 **Fails** (Stripped by cloud sync & Windows) | 🟡 Requires server hosting / maintenance | 🟢 **100% Solid** (Syncs over SMB, LucidLink, Drive) |
| **Save/Read Performance** | 🔴 Slow (Muxing/Atom parsing) | 🟢 Fast (<1ms) | 🟡 Network latency dependent | 🟢 **Near Instant** (<1ms text I/O) |
| **NLE Interoperability** | 🔴 Proprietary atom reading required | 🔴 Inaccessible to other tools | 🔴 Requires database API export | 🟢 **Exportable to Premiere/Resolve markers** |
| **Implementation Complexity** | 🔴 High (AVAssetExport / FFMpeg atoms) | 🟡 Medium (AppKit POSIX xattr) | 🔴 High (Backend API + Auth + Conflict res) | 🟢 **Low / Clean** (Codable Swift struct) |

---

## 3. The Proposed Workflow (Frame.io Simplicity)

### A. Creating a Note
1. The user scrubs or pauses at any frame (e.g. `00:00:14:12`).
2. Pressing **`M`** (Marker) or clicking a **`[ + NOTE ]`** button on the transport bar opens an inline floating text input:
   ```text
   [ 00:00:14:12 ] Type note... (Press Return to save, Esc to cancel)
   ```
3. The user types their comment (e.g., *"Logo watermark opacity is too low"*), hits **`Enter`**:
   - A distinct marker pip appears on the timeline scrubber.
   - The companion `.qcnotes` file is updated immediately on disk.
   - Playback automatically resumes or remains paused depending on user preference.

### B. Reviewing & Navigating Notes
- **Hovering a Timeline Pip:** Hovering the mouse over a note marker on the timeline displays a floating tooltip with the timecode, author, and note text.
- **Clicking a Timeline Pip:** Jumps the playhead directly to the exact frame and highlights the note.
- **Notes Drawer / HUD:** A toggleable collapsable side-panel (or bottom drawer) showing a clean chronological list of all notes:
  - `[00:00:04:08]` John D. — *"Intro slate duration should be 2s, not 4s"*
  - `[00:00:14:12]` Sarah M. — *"Logo watermark opacity is too low"*
  - `[00:00:22:00]` Alex K. — *"Audio pop on right channel transition"*
- Clicking any row jumps the player playhead straight to that frame.

### C. Collaborator Experience
- Colleague opens the same project folder or file from the shared server/LucidLink.
- QCpie checks `fileURL.deletingPathExtension().appendingPathExtension("qcnotes")`.
- If the file exists, it decodes the notes in `< 2ms` and renders them onto the scrubber.
- Colleague adds their own note; it appends to the file. Both team members have matching notes without needing cloud accounts or logins.

---

## 4. Proposed Sidecar File Format Spec

To ensure maximum simplicity and longevity, the sidecar should use human-readable JSON (with an optional 1-click export to Premiere Markers CSV and DaVinci Resolve EDL).

### Example: `Commercial_V04_ProRes.mov.qcnotes`
```json
{
  "version": 1,
  "mediaFileName": "Commercial_V04_ProRes.mov",
  "fps": 25.0,
  "lastModified": "2026-09-07T14:30:00Z",
  "notes": [
    {
      "id": "A4B789C1-4D3E-4A12-B8F9-00124876ABC1",
      "frame": 108,
      "timecode": "00:00:04:08",
      "author": "Marcus (Editor)",
      "created": "2026-09-07T14:12:00Z",
      "color": "yellow",
      "text": "Intro slate duration should be 2.0s instead of 4.0s."
    },
    {
      "id": "B12389C1-4D3E-4A12-B8F9-00124876ABC2",
      "frame": 362,
      "timecode": "00:00:14:12",
      "author": "Sarah (Colorist)",
      "created": "2026-09-07T14:18:22Z",
      "color": "cyan",
      "text": "Slight green tint on edge pixels near bottom crop."
    }
  ]
}
```

### Why this format shines:
1. **Human-Readable & Safe:** Can be opened in TextEdit, Notepad, or VSCode if needed.
2. **Swift Native:** Encodes and decodes with zero third-party dependencies via standard Swift `Codable` (`JSONEncoder` / `JSONDecoder`).
3. **Author Attribution:** Defaults automatically to macOS system username (`NSFullUserName()` or `NSUserName()`), but allows editing.
4. **Color Coding (Optional):** Supports standard NLE marker colors (Yellow, Cyan, Green, Red) to categorize notes (e.g. *Editorial*, *Audio*, *Color*, *Glitch*).

---

## 5. Production Superpowers (Added Value for Post-Houses)

Implementing the sidecar architecture unlocks three high-value features for a production company at almost zero additional complexity:

1. **Direct NLE Import (Premiere & DaVinci Resolve Markers):**
   - In QCpie: click **`[ EXPORT TO PREMIERE ]`** or **`[ EXPORT TO RESOLVE ]`**.
   - Generates a standard `Markers.csv` or `Markers.edl`.
   - The assistant editor or conform editor imports it directly into Premiere Pro or DaVinci Resolve, and all client/director feedback markers appear directly on their edit timeline!
2. **Markdown / Email QC Report:**
   - A single button to **`[ COPY NOTES SUMMARY ]`** formatted cleanly:
     ```markdown
     ## QC Review Notes: Commercial_V04_ProRes.mov
     - 00:00:04:08 — Intro slate duration should be 2.0s instead of 4.0s (Marcus)
     - 00:00:14:12 — Slight green tint on edge pixels near bottom crop (Sarah)
     ```
   - Ready to paste into Slack, Teams, or an email to the client or director.
3. **Integration with Line Scanner (Tab 3 Glitch Findings):**
   - Detected 1-pixel edge line glitches can automatically be converted into timeline notes with one click (`[ CONVERT GLITCHES TO NOTES ]`), giving editors a ready-to-cut punch list.

---

## 6. Recommended Phase 1 MVP Scope

To keep it rock-solid with zero break points:

1. **Data Model:**
   - Swift struct `QCFileNote: Identifiable, Codable, Sendable`.
   - Companion manager `QCNotesStore` (actor or utility class) handling `load(for: URL)` and `save(notes:for: URL)`.
2. **Timeline Representation:**
   - Reuse existing `PlayerTimelineMarker` system in `TimelineScrubberView.swift` to render note markers with distinct styling (e.g. speech-bubble badge or colored vertical pip).
3. **Inline Note Popover / Input Bar:**
   - Pressing **`M`** pauses and reveals a minimal floating text input box anchored over the playhead. Pressing `Return` saves; `Esc` cancels.
4. **Notes Drawer / HUD:**
   - A collapsable side or bottom list showing timecoded rows. Clicking any row seeks the playhead to that exact frame.
5. **No Cloud, No Login, No Servers:**
   - 100% local-first. If files are on a shared drive, collaboration happens naturally via the file system.

---

## 7. Conclusion & Recommendation

| Question | Verdict |
| :--- | :--- |
| **Is it too ambitious?** | **No.** Highly feasible; the UI and playback foundations already exist. |
| **Embed into video container?** | **Strongly advise against.** Risky, slow, corruptible, breaks checksums. |
| **Recommended alternative?** | **Lightweight `.qcnotes` sidecar file** co-located with the video. |
| **Break point risk level?** | **Extremely Low.** Plain text JSON, zero dependencies, atomic writes. |

*This document is for architectural review and brainstorming. No production code has been modified.*
