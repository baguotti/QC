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
const EDGE_LABELS = { top: "Top", bottom: "Bottom", left: "Left", right: "Right", splitH: "Split (H)", splitV: "Split (V)" };

const $ = (id) => document.getElementById(id);
const logEl = $("log");
const log = (msg) => { logEl.textContent += msg + "\n"; console.log(msg); };
const status = (msg) => { $("status").textContent = msg; };
let scanning = false;

// MARK: Settings

const targetItems = () => Array.from($("target").querySelectorAll("sp-menu-item"));

function readForm() {
  const value = targetItems()[$("target").selectedIndex]?.getAttribute("value") ?? "#00FF00";
  const hex = value === "custom" ? ($("hex").value || "").trim().toUpperCase() : value;
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

function updateHexField() {
  $("hex").classList.toggle("hidden", readForm().targetChoice !== "custom");
}

$("target").addEventListener("change", () => { updateHexField(); saveForm(); });
for (const id of ["hex", "sensitivity", "splits", "useInOut"]) $(id).addEventListener("change", saveForm);
restoreForm();

// MARK: Scan

$("scan").addEventListener("click", () => {
  if (scanning) return;
  scanning = true;
  $("scan").setAttribute("disabled", "");
  logEl.textContent = "";
  scan().catch((e) => { status("Scan failed: " + e.message); log("ERROR: " + (e.stack || e)); })
    .finally(() => {
      scanning = false;
      $("scan").removeAttribute("disabled");
      $("progress").classList.add("hidden");
      writeLogFile();
    });
});

$("clear").addEventListener("click", async () => {
  const { project, sequence } = await active();
  if (!sequence) return;
  const n = await removeMarkers(project, sequence, null);
  status(`Removed ${n} LineFinder marker${n === 1 ? "" : "s"}.`);
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
  for (const name of [`${NAME}.json`, `${NAME}.progress`]) {
    const stale = await data.getEntry(name).catch(() => null);
    if (stale) await stale.delete();
  }
  const settingsFile = await data.createFile(`${NAME}.settings.json`, { overwrite: true });
  await settingsFile.write(JSON.stringify({
    target: form.target, anyColor: form.anyColor, sensitivity: form.sensitivity, splits: form.splits,
  }));
  const outPath = joinPath(data.nativePath, `${NAME}.json`);

  status("Scanning…");
  $("progress").value = 0;
  $("progress").classList.remove("hidden");
  $("results").textContent = "";
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
  log(`Result: ${result.frames} frames (${result.rendered} rendered) ${result.width}×${result.height} ${result.pixelFormat}, ` +
      `${result.seconds.toFixed(2)} s → ${(result.frames / result.seconds).toFixed(0)} fps, ${result.segments.length} segments`);

  // Segment frames count from the export start; startTicks is that start in sequence time.
  const start = BigInt(result.startTicks);
  if (range && start !== BigInt(range.inT.ticks)) log(`Note: export start ${start} ≠ In point ${range.inT.ticks}`);
  const end = BigInt(result.endTicks);
  const zero = await zeroPoint(sequence);

  const removed = await removeMarkers(project, sequence, { start, end });
  const segments = result.segments.map((s) => ({
    ...s,
    startTicks: start + BigInt(s.start) * tpf,
    durationTicks: BigInt(s.end - s.start + 1) * tpf,
  }));
  await addMarkers(project, sequence, segments, tpf, zero);
  showResults(sequence, segments, tpf, zero);

  const where = range ? "In/Out" : "sequence";
  const aborted = result.aborted ? " Stopped early." : "";
  status(segments.length
    ? `${segments.length} line${segments.length === 1 ? "" : "s"} found in ${result.frames} frames (${where}).${aborted}`
    : `No lines in ${result.frames} frames (${where}).${aborted}`);
  if (removed) log(`Replaced ${removed} older LineFinder markers in this range.`);
}

async function readProgress(folder) {
  try {
    const entry = await folder.getEntry(`${NAME}.progress`);
    const [done, total] = (await entry.read()).trim().split(/\s+/).map(Number);
    if (total > 0) {
      $("progress").value = Math.min(100, Math.round((done / total) * 100));
      status(`Scanning… ${done} / ${total} frames`);
    }
  } catch { /* not written yet */ }
}

// An unset In/Out reads as a huge negative time (-400000 s seen in 26.5).
async function inOut(sequence) {
  const inT = await sequence.getInPoint(), outT = await sequence.getOutPoint();
  return inT.seconds < 0 || outT.seconds <= inT.seconds ? null : { inT, outT };
}

async function zeroPoint(sequence) {
  try { return BigInt((await sequence.getZeroPoint()).ticks); } catch { return 0n; }
}

// MARK: Markers

function describe(s) {
  const edge = EDGE_LABELS[s.edge] ?? s.edge;
  return `${s.offColor ? "Off-colour · " : ""}${edge} · ${s.thickness}px`;
}

function detail(s, tpf, zero) {
  const frames = s.end - s.start + 1;
  const where = s.position < 0 ? "" : s.edge === "splitH" ? `, row ${s.position}` : s.edge === "splitV" ? `, column ${s.position}` : `, inside ${s.position} px bar`;
  return `${s.offColor ? "Off-colour line" : "Line glitch"}: ${EDGE_LABELS[s.edge] ?? s.edge} edge, ${s.thickness} px, ${s.color}${where}. ` +
         `${timecode(s.startTicks + zero, tpf)}–${timecode(s.startTicks + s.durationTicks - tpf + zero, tpf)} (${frames} frame${frames === 1 ? "" : "s"}).`;
}

async function addMarkers(project, sequence, segments, tpf, zero) {
  if (!segments.length) return;
  const markers = await ppro.Markers.getMarkers(sequence);
  project.lockedAccess(() => project.executeTransaction((tx) => {
    for (const s of segments) {
      tx.addAction(markers.createAddMarkerAction(
        `${MARKER_PREFIX} · ${describe(s)}`, "Comment",
        ppro.TickTime.createWithTicks(String(s.startTicks)), ppro.TickTime.createWithTicks(String(s.durationTicks)),
        detail(s, tpf, zero)));
    }
  }, "LineFinder: add markers"));

  const wanted = new Map(segments.map((s) => [`${s.startTicks}|${MARKER_PREFIX} · ${describe(s)}`, s.offColor ? ORANGE : RED]));
  const toColour = markers.getMarkers()
    .map((m) => [m, wanted.get(`${m.getStart().ticks}|${m.getName()}`)])
    .filter(([m, colour]) => colour != null && m.getColorIndex() !== colour);
  if (!toColour.length) return;
  project.lockedAccess(() => project.executeTransaction((tx) => {
    for (const [m, colour] of toColour) tx.addAction(m.createSetColorByIndexAction(colour));
  }, "LineFinder: colour markers"));
}

// Removes LineFinder markers, only those starting inside `range` when given. Returns how many.
async function removeMarkers(project, sequence, range) {
  const markers = await ppro.Markers.getMarkers(sequence);
  const doomed = markers.getMarkers().filter((m) => {
    if (!m.getName().startsWith(MARKER_PREFIX)) return false;
    if (!range) return true;
    const t = BigInt(m.getStart().ticks);
    return t >= range.start && t < range.end;
  });
  if (!doomed.length) return 0;
  project.lockedAccess(() => project.executeTransaction((tx) => {
    for (const m of doomed) tx.addAction(markers.createRemoveMarkerAction(m));
  }, "LineFinder: remove markers"));
  return doomed.length;
}

// MARK: Results

function showResults(sequence, segments, tpf, zero) {
  const list = $("results");
  list.textContent = "";
  for (const s of segments) {
    const row = document.createElement("div");
    row.className = "result" + (s.offColor ? " off" : "");
    const what = document.createElement("div");
    what.className = "what";
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.backgroundColor = s.color;
    what.appendChild(swatch);
    what.appendChild(document.createTextNode(describe(s)));
    const when = document.createElement("div");
    when.className = "when";
    const frames = s.end - s.start + 1;
    when.textContent = `${timecode(s.startTicks + zero, tpf)}  ${frames} fr  ${s.color}`;
    row.appendChild(what);
    row.appendChild(when);
    row.title = detail(s, tpf, zero);
    row.addEventListener("click", () =>
      sequence.setPlayerPosition(ppro.TickTime.createWithTicks(String(s.startTicks))).catch((e) => log("Jump failed: " + e.message)));
    list.appendChild(row);
  }
}

// HH:MM:SS:FF, non-drop-frame at the nominal rate (as QCpie shows timecodes).
function timecode(ticks, tpf) {
  const fps = Number((TICKS_PER_SECOND + tpf / 2n) / tpf);
  const frame = Number(ticks / tpf);
  const ff = frame % fps, s = Math.floor(frame / fps);
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}:${pad(ff)}`;
}

function joinPath(dir, name) {
  return dir + (dir.includes("\\") ? "\\" : "/") + name;
}

async function writeLogFile() {
  try {
    const file = await (await fs.getDataFolder()).createFile("panel-log.txt", { overwrite: true });
    await file.write(`${$("status").textContent}\n${logEl.textContent}`);
  } catch { /* debugging aid only */ }
}
