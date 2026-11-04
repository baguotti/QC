// LineFinder panel: Scan renders the sequence (or In/Out) through the LineFinder Analysis exporter, which runs
// linecore on every frame and writes segments; each segment becomes a red marker and a clickable result.
// Exporter contract: see premiere/exporter/LineFinderExporter.cpp.
const ppro = require("premierepro");
const fs = require("uxp").storage.localFileSystem;

const PRESET = "presets/LineFinder.epr";
const NAME = "scan";
const MARKER_PREFIX = "LineFinder";
const TICKS_PER_SECOND = 254016000000n;
const RED = 1;
const ORANGE = 3;
// Premiere slows down badly with thousands of markers (Any colour + seams on a long timeline can produce that).
const MAX_MARKERS = 500;
const MAX_ROWS = 500;
const RESULT_VERSION = 1;
const EDGE_LABELS = { top: "Top", bottom: "Bottom", left: "Left", right: "Right", splitH: "Split (H)", splitV: "Split (V)" };

const $ = (id) => document.getElementById(id);
const logEl = $("log");
const log = (msg) => { logEl.textContent += msg + "\n"; console.log(msg); };
// The status line doubles as the results list's empty state.
const status = (msg) => { $("status").textContent = msg; $("status").classList.toggle("hidden", !msg); };
const summary = (msg) => { $("summary").textContent = msg; };
let scanning = false;
let shownSequence = null;  // guid of the sequence whose results are listed
// The last scan of the listed sequence, so Not a Line and Restore can redo its markers and rows without a re-scan.
let lastScan = null;  // { project, sequence, range, segments, clock }

// MARK: Settings

const targetItems = () => Array.from($("target").querySelectorAll("sp-menu-item"));

function readForm() {
  const value = targetItems()[$("target").selectedIndex]?.getAttribute("value") ?? "#00FF00";
  const typed = ($("hex").value || "").trim().toUpperCase();
  const hex = value === "custom" ? (typed.startsWith("#") ? typed : "#" + typed) : value;
  return {
    targetChoice: value,
    target: value === "any" ? "#00FF00" : hex,
    anyColor: value === "any",
    sensitivity: Number($("sensitivity").value) / 100,
    splits: $("splits").checked,
    useInOut: $("useInOut").checked,
    hex: $("hex").value || "",
  };
}

function restoreForm() {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem("linefinder") || "{}"); } catch { /* defaults */ }
  const index = targetItems().findIndex((i) => i.getAttribute("value") === (saved.targetChoice ?? "#00FF00"));
  $("target").selectedIndex = Math.max(0, index);
  $("hex").value = saved.hex ?? "";
  $("sensitivity").value = Math.round((saved.sensitivity ?? 0.5) * 100);
  $("splits").checked = !!saved.splits;
  $("useInOut").checked = saved.useInOut ?? true;
  updateHexField();
}

function saveForm() {
  try { localStorage.setItem("linefinder", JSON.stringify(readForm())); } catch { /* not essential */ }
}

// Shows the hex field for Custom and paints the swatch next to the picker (dashed while a custom hex is incomplete).
function updateHexField() {
  const form = readForm();
  $("hex").classList.toggle("hidden", form.targetChoice !== "custom");
  const swatch = $("targetSwatch");
  const valid = /^#[0-9A-F]{6}$/.test(form.target);
  swatch.classList.toggle("any", form.anyColor);
  swatch.classList.toggle("unset", !form.anyColor && !valid);
  swatch.style.backgroundColor = !form.anyColor && valid ? form.target : "";
}

$("target").addEventListener("change", () => { updateHexField(); saveForm(); });
$("hex").addEventListener("input", updateHexField);
for (const id of ["hex", "sensitivity", "splits", "useInOut"]) $(id).addEventListener("change", saveForm);
const showSensitivity = () => { $("sensitivityValue").textContent = String(Math.round(Number($("sensitivity").value))); };
$("sensitivity").addEventListener("input", showSensitivity);
$("sensitivity").addEventListener("change", showSensitivity);
restoreForm();
showSensitivity();

// MARK: Scan

// While scanning, Scan becomes Cancel: it leaves a scan.cancel file that the exporter checks 4× a second.
$("scan").addEventListener("click", () => {
  if (scanning) return requestCancel();
  scanning = true;
  setScanButton("Cancel");
  $("clear").setAttribute("disabled", "");
  logEl.textContent = "";
  scan().catch((e) => { status("Scan failed: " + e.message); log("ERROR: " + (e.stack || e)); })
    .finally(() => {
      scanning = false;
      setScanButton("Scan");
      $("clear").removeAttribute("disabled");
      $("progressRow").classList.add("hidden");
      writeLogFile();
    });
});

function setScanButton(label) {
  $("scan").textContent = label;
  $("scan").setAttribute("variant", label === "Scan" ? "cta" : "secondary");
  $("scan").removeAttribute("disabled");
}

async function requestCancel() {
  $("scan").setAttribute("disabled", "");
  $("progressLabel").textContent = "Stopping…";
  log("Cancel requested");
  await (await fs.getDataFolder()).createFile(`${NAME}.cancel`, { overwrite: true }).then((f) => f.write("1"));
}

$("clear").addEventListener("click", async () => {
  if (scanning) return;
  const { project, sequence } = await active();
  if (!sequence) return;
  const markers = await ppro.Markers.getMarkers(sequence);
  const doomed = lineFinderMarkers(markers, null);
  const n = doomed.length;
  if (n && !transaction(project, "LineFinder: clear markers", (tx) => removeActions(tx, markers, doomed))) {
    return status("Premiere refused to remove the markers.");
  }
  if (shownSequence === String(sequence.guid)) {
    clearResults();
    summary("");
    shownSequence = null;
    lastScan = null;
    showRestore(0);
  }
  status(n ? `Removed ${n} LineFinder marker${n === 1 ? "" : "s"}.` : "No LineFinder markers on this sequence.");
});

async function active() {
  const project = await ppro.Project.getActiveProject();
  const sequence = project && await project.getActiveSequence();
  if (!sequence) status("Open a sequence first.");
  return { project, sequence };
}

async function scan() {
  const form = readForm();
  if (!form.anyColor && !/^#[0-9A-F]{6}$/.test(form.target)) return status("Enter a colour as #RRGGBB.");
  const { project, sequence } = await active();
  if (!sequence) return;

  const preset = await (await fs.getPluginFolder()).getEntry(PRESET).catch(() => null);
  if (!preset) return status("Missing " + PRESET + ".");

  const tpf = BigInt(await sequence.getTimebase());
  const range = form.useInOut ? await inOut(sequence) : null;
  if (form.useInOut && !range) log("No In/Out set: scanning the whole sequence.");

  const data = await fs.getDataFolder();
  for (const name of [`${NAME}.json`, `${NAME}.progress`, `${NAME}.cancel`]) {
    const stale = await data.getEntry(name).catch(() => null);
    if (stale) await stale.delete();
  }
  const settingsFile = await data.createFile(`${NAME}.settings.json`, { overwrite: true });
  await settingsFile.write(JSON.stringify({
    target: form.target, anyColor: form.anyColor, sensitivity: form.sensitivity, splits: form.splits,
  }));
  const outPath = joinPath(data.nativePath, `${NAME}.json`);

  status("");
  summary("");
  $("progressLabel").textContent = "Scanning";
  $("progress").value = 0;
  $("progressRow").classList.remove("hidden");
  clearResults();
  const poll = setInterval(() => readProgress(data), 250);
  const t0 = Date.now();
  let ok;
  try {
    ok = await ppro.EncoderManager.getManager().exportSequence(
      sequence, ppro.Constants.ExportType.IMMEDIATELY, outPath, preset.nativePath, !range);
  } finally {
    clearInterval(poll);
  }
  log(`exportSequence → ${ok} after ${((Date.now() - t0) / 1000).toFixed(2)} s`);
  const entry = ok && await data.getEntry(`${NAME}.json`).catch(() => null);
  if (!entry) return status("Scan didn't finish (cancelled, or the exporter isn't installed).");
  const result = JSON.parse(await entry.read());
  if (result.version !== RESULT_VERSION || result.milliseconds == null) {
    return status("The installed LineFinder exporter doesn't match this panel: reinstall both.");
  }
  const seconds = Math.max(0.001, result.milliseconds / 1000);
  log(`Result: ${result.frames} frames (${result.rendered} rendered, ${result.skipped} skipped, first frame number ` +
      `${result.firstFrameNumber}) ${result.width}×${result.height} ${result.pixelFormat}, ${seconds.toFixed(2)} s → ` +
      `${(result.frames / seconds).toFixed(0)} fps, ${result.segments.length} segments`);
  if (result.frames === 0) return status("Nothing was rendered: is there video in the scanned range?");

  // Segment frames count from the export start; startTicks is that start in sequence time.
  const start = BigInt(result.startTicks);
  if (range && start !== BigInt(range.inT.ticks)) log(`Note: export start ${start} ≠ In point ${range.inT.ticks}`);
  const end = BigInt(result.endTicks);
  const clock = await timecodeFormat(sequence, tpf);
  log(`Timecode: ${clock.fps} fps${clock.drop ? " drop-frame" : ""} (display format ${clock.displayType}), zero ${clock.zero}`);

  const all = result.segments.map((s) => ({
    ...s,
    startTicks: start + BigInt(s.start) * tpf,
    durationTicks: BigInt(s.end - s.start + 1) * tpf,
  }));
  lastScan = { project, sequence, range: { start, end }, segments: all, clock };
  const { visible: segments, hidden } = splitDismissed(sequence, all, tpf);
  const { removed, written } = await replaceMarkers(project, sequence, { start, end }, segments.slice(0, MAX_MARKERS), clock);
  showResults(project, sequence, segments, clock);
  showRestore(hidden.length);

  const where = range ? "In/Out" : "whole sequence";
  const lines = `${segments.length} line${segments.length === 1 ? "" : "s"}`;
  summary(result.aborted ? `${lines} · stopped at ${result.frames} frames` : `${lines} · ${result.frames} frames · ${where}`);
  const notes = [];
  if (result.aborted) notes.push(segments.length ? "Scan stopped early: later frames weren't checked." : "Scan stopped early.");
  if (result.skipped) notes.push(`${result.skipped} frames couldn't be analysed (unexpected pixel format).`);
  if (!written) notes.push("Premiere refused to update the markers.");
  if (segments.length > MAX_MARKERS) notes.push(`Markers added for the first ${MAX_MARKERS} lines only.`);
  if (hidden.length) notes.push(`${hidden.length} hidden as Not a Line.`);
  if (!segments.length) notes.unshift(`No lines found in ${result.frames} frames (${where}).`);
  status(notes.join(" "));
  if (removed) log(`Replaced ${removed} older LineFinder markers in this range.`);
}

async function readProgress(folder) {
  try {
    const entry = await folder.getEntry(`${NAME}.progress`);
    const [done, total] = (await entry.read()).trim().split(/\s+/).map(Number);
    if (Number.isFinite(done) && Number.isFinite(total) && total > 0) {
      $("progress").value = Math.min(100, Math.round((done / total) * 100));
      $("progressLabel").textContent = `Scanning ${done} / ${total} frames`;
    }
  } catch { /* not written yet */ }
}

// An unset In/Out reads as a huge negative time (-400000 s seen in 26.5).
async function inOut(sequence) {
  const inT = await sequence.getInPoint(), outT = await sequence.getOutPoint();
  return inT.seconds < 0 || outT.seconds <= inT.seconds ? null : { inT, outT };
}

// Timecode as the timeline shows it: the sequence's start timecode and its display format. TimeDisplay codes are taken
// to match ExtendScript's (102 = 29.97 drop, 106 = 59.94 drop); the log records the code for checking.
const DROP_FRAME_DISPLAYS = new Set([102, 106]);

async function timecodeFormat(sequence, tpf) {
  const fps = Number((TICKS_PER_SECOND + tpf / 2n) / tpf);
  let zero = 0n, displayType = null;
  try { zero = BigInt((await sequence.getZeroPoint()).ticks); } catch { /* starts at 0 */ }
  try { displayType = (await sequence.getSequenceVideoTimeDisplayFormat()).type; } catch { /* not available */ }
  const drop = DROP_FRAME_DISPLAYS.has(displayType) && (fps === 30 || fps === 60);
  return { tpf, fps, zero, drop, displayType };
}

// MARK: Markers

function describe(s) {
  const edge = EDGE_LABELS[s.edge] ?? s.edge;
  return `${s.offColor ? "Off-colour · " : ""}${edge} · ${s.thickness}px`;
}

function detail(s, clock) {
  const frames = s.end - s.start + 1;
  const where = s.position < 0 ? "" : s.edge === "splitH" ? `, row ${s.position}` : s.edge === "splitV" ? `, column ${s.position}` : `, inside ${s.position} px bar`;
  return `${s.offColor ? "Off-colour line" : "Line glitch"}: ${EDGE_LABELS[s.edge] ?? s.edge} edge, ${s.thickness} px, ${s.color}${where}. ` +
         `${timecode(s.startTicks, clock)}–${timecode(s.startTicks + s.durationTicks - clock.tpf, clock)} (${frames} frame${frames === 1 ? "" : "s"}).`;
}

// One undo step. Returns false when Premiere rejects it.
function transaction(project, name, build) {
  let ok = false;
  project.lockedAccess(() => { ok = project.executeTransaction(build, name); });
  return ok !== false;
}

// LineFinder markers, only those starting inside `range` when given.
function lineFinderMarkers(markers, range) {
  return markers.getMarkers().filter((m) => {
    if (!m.getName().startsWith(MARKER_PREFIX)) return false;
    if (!range) return true;
    const t = BigInt(m.getStart().ticks);
    return t >= range.start && t < range.end;
  });
}

function removeActions(tx, markers, doomed) {
  for (const m of doomed) tx.addAction(markers.createRemoveMarkerAction(m));
}

// Replaces the LineFinder markers in `range` with one per segment in a single undo step, then colours them (a marker
// can only be coloured once it exists, so that is a second step). Returns how many old markers were removed and
// whether Premiere accepted the change.
async function replaceMarkers(project, sequence, range, segments, clock) {
  const markers = await ppro.Markers.getMarkers(sequence);
  const doomed = lineFinderMarkers(markers, range);
  if (!doomed.length && !segments.length) return { removed: 0, written: true };
  const written = transaction(project, "LineFinder: markers", (tx) => {
    removeActions(tx, markers, doomed);
    for (const s of segments) {
      tx.addAction(markers.createAddMarkerAction(
        `${MARKER_PREFIX} · ${describe(s)}`, "Comment",
        ppro.TickTime.createWithTicks(String(s.startTicks)), ppro.TickTime.createWithTicks(String(s.durationTicks)),
        detail(s, clock)));
    }
  });

  const wanted = new Map(segments.map((s) => [`${s.startTicks}|${MARKER_PREFIX} · ${describe(s)}`, s.offColor ? ORANGE : RED]));
  const toColour = markers.getMarkers()
    .map((m) => [m, wanted.get(`${m.getStart().ticks}|${m.getName()}`)])
    .filter(([m, colour]) => colour != null && m.getColorIndex() !== colour);
  if (written && toColour.length) {
    transaction(project, "LineFinder: colour markers", (tx) => {
      for (const [m, colour] of toColour) tx.addAction(m.createSetColorByIndexAction(colour));
    });
  }
  return { removed: written ? doomed.length : 0, written };
}

// MARK: Results

// Rows for the first MAX_ROWS segments (UXP lays out thousands of rows slowly); clicking one moves the playhead there,
// bringing the scanned sequence to the front if another one is active.
function clearResults() {
  $("results").textContent = "";
  $("columns").classList.add("hidden");
}

function cell(className, text) {
  const el = document.createElement("div");
  el.className = className;
  el.textContent = text;
  return el;
}

function showResults(project, sequence, segments, clock) {
  const list = $("results");
  clearResults();
  shownSequence = String(sequence.guid);
  $("columns").classList.toggle("hidden", !segments.length);
  for (const s of segments.slice(0, MAX_ROWS)) {
    const row = document.createElement("div");
    row.className = "row result";
    const swatch = cell(s.offColor ? "swatch off" : "swatch", "");
    swatch.style.backgroundColor = s.color;
    const edge = cell("edge", EDGE_LABELS[s.edge] ?? s.edge);
    if (s.offColor) {
      const tag = document.createElement("span");
      tag.className = "tag muted";
      tag.textContent = "off-colour";
      edge.appendChild(tag);
    }
    const frames = s.end - s.start + 1;
    const cells = [swatch, edge, cell("size muted", `${s.thickness} px`), cell("tc", timecode(s.startTicks, clock)),
                   cell("frames muted", `${frames} fr`)];
    const dismiss = cell("dismiss muted", "×");
    dismiss.title = "Not a Line: hide this finding and its marker on later scans too";
    dismiss.addEventListener("click", (event) => {
      event.stopPropagation();
      notALine(s).catch((e) => log("Not a Line failed: " + e.message));
    });
    cells.push(dismiss);
    for (const el of cells) row.appendChild(el);
    row.title = detail(s, clock);
    row.addEventListener("click", () => {
      for (const r of list.querySelectorAll(".result.selected")) r.classList.remove("selected");
      row.classList.add("selected");
      jumpTo(project, sequence, s.startTicks).catch((e) => log("Jump failed: " + e.message));
    });
    list.appendChild(row);
  }
  if (segments.length > MAX_ROWS) {
    const more = document.createElement("div");
    more.className = "more muted";
    more.textContent = `+ ${segments.length - MAX_ROWS} more (see the markers)`;
    list.appendChild(more);
  }
}

async function jumpTo(project, sequence, ticks) {
  const current = await project.getActiveSequence();
  if (!current || String(current.guid) !== String(sequence.guid)) await project.setActiveSequence(sequence);
  await sequence.setPlayerPosition(ppro.TickTime.createWithTicks(String(ticks)));
}

// MARK: Not a Line

// Dismissed findings per sequence (localStorage, keyed by sequence guid): edge + tick range. A later scan hides a
// finding on the same edge that overlaps one within 2 frames, like QCpie's Not a Line.
const DISMISS_KEY = "linefinder.dismissed.";
const DISMISS_SLACK_FRAMES = 2n;

function dismissals(sequence) {
  try { return JSON.parse(localStorage.getItem(DISMISS_KEY + sequence.guid) || "[]"); } catch { return []; }
}

function saveDismissals(sequence, list) {
  try {
    if (list.length) localStorage.setItem(DISMISS_KEY + sequence.guid, JSON.stringify(list));
    else localStorage.removeItem(DISMISS_KEY + sequence.guid);
  } catch { /* not essential */ }
}

function isDismissed(s, list, tpf) {
  const slack = DISMISS_SLACK_FRAMES * tpf;
  const end = s.startTicks + s.durationTicks;
  return list.some((d) => d.edge === s.edge && s.startTicks < BigInt(d.end) + slack && end > BigInt(d.start) - slack);
}

function splitDismissed(sequence, segments, tpf) {
  const list = dismissals(sequence);
  const visible = [], hidden = [];
  for (const s of segments) (list.length && isDismissed(s, list, tpf) ? hidden : visible).push(s);
  return { visible, hidden };
}

async function notALine(s) {
  if (!lastScan || scanning) return;
  const { sequence } = lastScan;
  const list = dismissals(sequence);
  list.push({ edge: s.edge, start: String(s.startTicks), end: String(s.startTicks + s.durationTicks) });
  saveDismissals(sequence, list);
  await redrawLastScan("Hidden as Not a Line.");
}

// Re-applies the dismissals to the last scan: markers in its range and the rows.
async function redrawLastScan(message) {
  const { project, sequence, range, segments, clock } = lastScan;
  const { visible, hidden } = splitDismissed(sequence, segments, clock.tpf);
  const { written } = await replaceMarkers(project, sequence, range, visible.slice(0, MAX_MARKERS), clock);
  showResults(project, sequence, visible, clock);
  showRestore(hidden.length);
  summary(`${visible.length} line${visible.length === 1 ? "" : "s"}${hidden.length ? ` · ${hidden.length} hidden` : ""}`);
  status(written ? (visible.length ? "" : message) : "Premiere refused to update the markers.");
}

function showRestore(count) {
  $("restore").textContent = count ? `Restore ${count}` : "Restore";
  $("restore").classList.toggle("hidden", !count);
}

// Brings back every Not a Line on the listed sequence.
$("restore").addEventListener("click", async () => {
  if (!lastScan || scanning) return;
  saveDismissals(lastScan.sequence, []);
  await redrawLastScan("").catch((e) => log("Restore failed: " + e.message));
});

// Timeline timecode for a sequence time: HH:MM:SS:FF, or HH:MM:SS;FF drop-frame (29.97 / 59.94 DF).
function timecode(ticks, clock) {
  const { tpf, fps, zero, drop } = clock;
  let frame = Number((ticks + zero) / tpf);
  if (drop) {
    // Drop-frame skips 2 (4 at 59.94) frame numbers each minute, except every tenth minute.
    const dropped = fps === 60 ? 4 : 2;
    const perTenMinutes = fps * 600 - dropped * 9;
    const perMinute = fps * 60 - dropped;
    const tens = Math.floor(frame / perTenMinutes);
    const rest = frame % perTenMinutes;
    frame += dropped * 9 * tens + (rest > dropped ? dropped * Math.floor((rest - dropped) / perMinute) : 0);
  }
  const ff = frame % fps, s = Math.floor(frame / fps);
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}${drop ? ";" : ":"}${pad(ff)}`;
}

function joinPath(dir, name) {
  return dir + (dir.includes("\\") ? "\\" : "/") + name;
}

async function writeLogFile() {
  try {
    const file = await (await fs.getDataFolder()).createFile("panel-log.txt", { overwrite: true });
    await file.write(`${$("summary").textContent}\n${$("status").textContent}\n${logEl.textContent}`);
  } catch { /* debugging aid only */ }
}

// MARK: Updates

// On opening (at most every 6 h) the panel asks GitHub for the latest QCpie release, which carries
// LineFinder-<version>.pkg. A newer one shows a banner: Update downloads the .pkg and opens it in Installer, which
// updates the exporter and the panel together; Premiere then needs a restart.
const RELEASES = "https://api.github.com/repos/baguotti/QC/releases/latest";
const RELEASES_PAGE = "https://github.com/baguotti/QC/releases/latest";
const UPDATE_KEY = "linefinder.update";
const CHECK_EVERY_MS = 6 * 3600 * 1000;
let update = null;  // { version, url, name }

function newer(a, b) {
  const pa = a.split(".").map(Number), pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d > 0;
  }
  return false;
}

async function installedVersion() {
  const manifest = await (await fs.getPluginFolder()).getEntry("manifest.json");
  return JSON.parse(await manifest.read()).version;
}

async function checkForUpdate() {
  const installed = await installedVersion();
  let cached = null;
  try { cached = JSON.parse(localStorage.getItem(UPDATE_KEY) || "null"); } catch { /* check again */ }
  let latest = cached && Date.now() - cached.checked < CHECK_EVERY_MS ? cached.latest : undefined;
  if (latest === undefined) {
    const response = await fetch(RELEASES, { headers: { Accept: "application/vnd.github+json" } });
    if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
    const asset = ((await response.json()).assets || []).find((a) => /^LineFinder-[\d.]+\.pkg$/.test(a.name));
    latest = asset ? { version: asset.name.slice(11, -4), url: asset.browser_download_url, name: asset.name } : null;
    try { localStorage.setItem(UPDATE_KEY, JSON.stringify({ checked: Date.now(), latest })); } catch { /* fine */ }
  }
  if (!latest || !newer(latest.version, installed)) return;
  update = latest;
  $("updateText").textContent = `LineFinder ${latest.version} is available (you have ${installed}).`;
  $("update").classList.remove("hidden");
}

$("updateButton").addEventListener("click", async () => {
  if (!update || $("updateButton").hasAttribute("disabled")) return;
  const button = $("updateButton");
  button.setAttribute("disabled", "");
  $("updateText").textContent = `Downloading ${update.version}…`;
  try {
    const response = await fetch(update.url);
    if (!response.ok) throw new Error(`download answered ${response.status}`);
    const bytes = await response.arrayBuffer();
    const file = await (await fs.getDataFolder()).createFile(update.name, { overwrite: true });
    await file.write(bytes, { format: require("uxp").storage.formats.binary });
    await require("uxp").shell.openPath(file.nativePath);
    $("updateText").textContent = "Click Install in Installer, then restart Premiere Pro.";
    button.classList.add("hidden");
  } catch (e) {
    log("Update failed: " + (e.stack || e));
    $("updateText").textContent = "Couldn't download the update. Opening the download page instead.";
    require("uxp").shell.openExternal(RELEASES_PAGE).catch(() => {});
    button.removeAttribute("disabled");
  }
});

checkForUpdate().catch((e) => log("Update check failed: " + e.message));
