// LineFinder spike panel: run the frame-counting exporter on the active sequence,
// read {"frames": N}, drop one red marker, log timings and which marker fields stuck.
const ppro = require("premierepro");
const fs = require("uxp").storage.localFileSystem;

const PRESET = "presets/LineFinderSpike.epr";
const RESULT = "spike.json";
const TIMEOUT_MS = 30 * 60 * 1000;
const RED = 1;

const logEl = document.getElementById("log");
const log = (msg) => { logEl.textContent += msg + "\n"; console.log(msg); };

document.getElementById("scan").addEventListener("click", () => {
  logEl.textContent = "";
  scan(document.getElementById("useInOut").checked).catch((e) => log("ERROR: " + (e.stack || e)));
});

async function scan(useInOut) {
  const project = await ppro.Project.getActiveProject();
  const sequence = project && await project.getActiveSequence();
  if (!sequence) return log("No active sequence.");

  const preset = await (await fs.getPluginFolder()).getEntry(PRESET).catch(() => null);
  if (!preset) return log("Missing " + PRESET + " (save one from Export Settings with the LineFinder Analysis format).");

  const dataFolder = await fs.getDataFolder();
  const stale = await dataFolder.getEntry(RESULT).catch(() => null);
  if (stale) await stale.delete();
  const outPath = dataFolder.nativePath + (dataFolder.nativePath.includes("\\") ? "\\" : "/") + RESULT;

  const encoder = ppro.EncoderManager.getManager();
  listenEncoderEvents(encoder);

  log(`Export → ${outPath}\nRange: ${useInOut ? "In/Out" : "whole sequence"}`);
  const t0 = Date.now();
  const ok = await encoder.exportSequence(sequence, ppro.Constants.ExportType.IMMEDIATELY, outPath, preset.nativePath, !useInOut);
  log(`exportSequence returned ${ok} after ${Date.now() - t0} ms`);
  if (!ok) return;

  const result = await waitForResult(dataFolder, t0);
  if (!result) return log("Timed out waiting for " + RESULT);
  const secs = (Date.now() - t0) / 1000;
  log(`frames=${result.frames} in ${secs.toFixed(2)} s → ${(result.frames / secs).toFixed(1)} fps`);

  await addMarker(project, sequence, useInOut, `LineFinder · spike · ${result.frames} frames`);
}

function listenEncoderEvents(encoder) {
  const events = ["EVENT_RENDER_PROGRESS", "EVENT_RENDER_COMPLETE", "EVENT_RENDER_ERROR", "EVENT_RENDER_CANCEL"];
  for (const name of events) {
    const type = ppro.EncoderManager[name];
    if (!type || listenEncoderEvents.bound?.has(type)) continue;
    try {
      ppro.EventManager.addEventListener(encoder, type, (e) => log(`${name}${e && e.progress != null ? " " + e.progress : ""}`));
      (listenEncoderEvents.bound ??= new Set()).add(type);
    } catch (e) {
      log(`No listener for ${name}: ${e.message}`);
    }
  }
}

async function waitForResult(folder, t0) {
  while (Date.now() - t0 < TIMEOUT_MS) {
    const entry = await folder.getEntry(RESULT).catch(() => null);
    if (entry) {
      try { return JSON.parse(await entry.read()); } catch { /* still being written */ }
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  return null;
}

async function addMarker(project, sequence, useInOut, name) {
  const markers = await ppro.Markers.getMarkers(sequence);
  const start = useInOut ? await sequence.getInPoint() : ppro.TickTime.TIME_ZERO;
  const oneFrame = ppro.TickTime.createWithTicks(String(await sequence.getTimebase()));
  // Spike check #3: a real segment marker needs duration > 1 frame; use 10 frames.
  const duration = ppro.TickTime.createWithTicks(String(oneFrame.ticksNumber * 10));
  const comment = "LineFinder spike marker";

  project.lockedAccess(() => project.executeTransaction((tx) => {
    tx.addAction(markers.createAddMarkerAction(name, "Comment", start, duration, comment));
  }, "LineFinder: add marker"));

  const marker = (await markers.getMarkers()).find((m) => m.getName() === name);
  if (!marker) return log("Marker not found after add.");
  try {
    project.lockedAccess(() => project.executeTransaction((tx) => {
      tx.addAction(marker.createSetColorByIndexAction(RED));
    }, "LineFinder: colour marker"));
  } catch (e) {
    log("Colour failed: " + e.message);
  }

  log(`Marker: name=${marker.getName()} start=${marker.getStart().seconds}s ` +
      `duration=${marker.getDuration().seconds}s colour=${marker.getColorIndex?.()} comment=${marker.getComments()}`);
}
