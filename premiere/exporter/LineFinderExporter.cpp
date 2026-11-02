// LineFinder Analysis exporter: Premiere renders the export range and pushes each frame to onFrame through
// DoMultiPassExportLoop; linecore scans it. No media is written: the "output file" is results JSON.
//
// Contract with the panel, for an output path <name>.json:
//   <name>.settings.json  (panel → exporter) {"target": "#00FF00", "anyColor": false, "sensitivity": 0.5,
//                                              "splits": false, "persistence": 6}
//   <name>.progress       (exporter → panel) "<frames done> <total>", rewritten at most 4× a second
//   <name>.cancel         (panel → exporter) exists = stop; checked with each progress write
//   <name>.json           (exporter → panel) frames, timing, startTicks/ticksPerFrame and segments (frame numbers
//                                              from the export start, end inclusive)

#include <PrSDKExport.h>
#include <PrSDKExportFileSuite.h>
#include <PrSDKExportInfoSuite.h>
#include <PrSDKExportParamSuite.h>
#include <PrSDKExporterUtilitySuite.h>
#include <PrSDKPPixSuite.h>
#include <PrSDKTimeSuite.h>

#include "linecore.h"

#ifdef _WIN32
#include <windows.h>
#endif

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr csSDK_uint32 kFileType = 'LFnd';

struct Instance {
	SPBasicSuite* spBasic = nullptr;
	PrSDKExportParamSuite* params = nullptr;
	PrSDKExportInfoSuite* info = nullptr;
	PrSDKExportFileSuite* file = nullptr;
	PrSDKExporterUtilitySuite* utility = nullptr;
	PrSDKPPixSuite* ppix = nullptr;
	PrSDKTimeSuite* time = nullptr;
};

using Clock = std::chrono::steady_clock;

// The host may call onFrame from several threads: detectors come from a pool, the segmenter is locked.
struct Scan {
	Instance* instance;
	lc_settings settings;
	lc_segmenter* segmenter;
	std::string progressPath, cancelPath, base;
	std::vector<long long> dumpFrames;  // debugging: frames saved as <name>.frame<N>.<w>x<h>.bgra, top row first
	std::atomic<bool> cancelled{false};
	csSDK_uint64 total = 0;

	std::mutex lock;
	std::vector<lc_detector*> idle;
	std::vector<lc_detector*> all;
	std::atomic<csSDK_uint64> frames{0}, rendered{0};
	csSDK_int32 width = 0, height = 0;
	PrPixelFormat format = PrPixelFormat_Invalid;
	Clock::time_point lastProgress = Clock::now();

	lc_detector* take() {
		std::lock_guard<std::mutex> g(lock);
		if (idle.empty()) {
			all.push_back(lc_detector_create(&settings));
			return all.back();
		}
		lc_detector* d = idle.back();
		idle.pop_back();
		return d;
	}
	void give(lc_detector* d) {
		std::lock_guard<std::mutex> g(lock);
		idle.push_back(d);
	}
	~Scan() {
		for (auto* d : all) lc_detector_destroy(d);
	}
};

template <class T>
void acquire(SPBasicSuite* sp, const char* name, int version, T*& out) {
	sp->AcquireSuite(name, version, const_cast<const void**>(reinterpret_cast<void**>(&out)));
}

void utf16(const char* in, prUTF16Char* out, size_t capacity = 256) {
	size_t i = 0;
	for (; in[i] && i + 1 < capacity; ++i) out[i] = static_cast<prUTF16Char>(in[i]);
	out[i] = 0;
}

std::string utf8(const prUTF16Char* s) {
	std::string out;
	for (size_t i = 0; s[i]; ++i) {
		char32_t c = s[i];
		if (c >= 0xD800 && c < 0xDC00 && s[i + 1] >= 0xDC00 && s[i + 1] < 0xE000)
			c = 0x10000 + ((c - 0xD800) << 10) + (s[++i] - 0xDC00);
		if (c < 0x80) out += char(c);
		else if (c < 0x800) { out += char(0xC0 | c >> 6); out += char(0x80 | (c & 0x3F)); }
		else if (c < 0x10000) { out += char(0xE0 | c >> 12); out += char(0x80 | (c >> 6 & 0x3F)); out += char(0x80 | (c & 0x3F)); }
		else { out += char(0xF0 | c >> 18); out += char(0x80 | (c >> 12 & 0x3F)); out += char(0x80 | (c >> 6 & 0x3F)); out += char(0x80 | (c & 0x3F)); }
	}
	return out;
}

FILE* openFile(const std::string& path, const char* mode) {
#ifdef _WIN32
	std::wstring wpath, wmode;
	int n = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
	wpath.resize(n);
	MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wpath.data(), n);
	for (const char* m = mode; *m; ++m) wmode += wchar_t(*m);
	return _wfopen(wpath.c_str(), wmode.c_str());
#else
	return std::fopen(path.c_str(), mode);
#endif
}

void removeFile(const std::string& path) {
#ifdef _WIN32
	int n = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
	std::wstring wpath(n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wpath.data(), n);
	_wremove(wpath.c_str());
#else
	std::remove(path.c_str());
#endif
}

std::string readFile(const std::string& path) {
	std::string text;
	if (FILE* f = openFile(path, "rb")) {
		char buf[4096];
		size_t n;
		while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) text.append(buf, n);
		std::fclose(f);
	}
	return text;
}

// Value text after "key": in a flat JSON object (the panel writes only strings, numbers and booleans).
const char* jsonValue(const std::string& json, const char* key) {
	std::string quoted = std::string("\"") + key + "\"";
	size_t at = json.find(quoted);
	if (at == std::string::npos) return nullptr;
	at = json.find(':', at + quoted.size());
	if (at == std::string::npos) return nullptr;
	const char* p = json.c_str() + at + 1;
	while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') ++p;
	return p;
}

lc_settings readSettings(const std::string& path) {
	lc_settings s = lc_settings_default();
	const std::string json = readFile(path);
	if (json.empty()) return s;
	if (const char* v = jsonValue(json, "target"); v && *v == '"') {
		unsigned r, g, b;
		if (std::sscanf(v, "\"#%02x%02x%02x\"", &r, &g, &b) == 3) {
			s.target_r = uint8_t(r); s.target_g = uint8_t(g); s.target_b = uint8_t(b);
			// QCpie's colour tolerance: tight for black / white targets.
			bool hueless = (r <= 15 && g <= 15 && b <= 15) || (r >= 240 && g >= 240 && b >= 240);
			s.tolerance = hueless ? 0.03 : 0.25;
		}
	}
	if (const char* v = jsonValue(json, "anyColor")) s.any_color = std::strncmp(v, "true", 4) == 0;
	if (const char* v = jsonValue(json, "splits")) s.scan_splits = std::strncmp(v, "true", 4) == 0;
	if (const char* v = jsonValue(json, "sensitivity")) s.sensitivity = std::strtod(v, nullptr);
	if (const char* v = jsonValue(json, "persistence")) s.persistence_frames = int(std::strtol(v, nullptr, 10));
	return s;
}

// "dumpFrames": [12, 60] in the settings: frames to save raw, for comparing Premiere's pixels with other decoders.
std::vector<long long> readDumpFrames(const std::string& path) {
	std::vector<long long> frames;
	const std::string json = readFile(path);
	const char* v = jsonValue(json, "dumpFrames");
	if (!v || *v != '[') return frames;
	for (const char* p = v + 1; *p && *p != ']';) {
		char* end = nullptr;
		long long n = std::strtoll(p, &end, 10);
		if (end == p) { ++p; continue; }
		frames.push_back(n);
		p = end;
	}
	return frames;
}

const char* edgeName(lc_edge e) {
	static const char* names[] = {"top", "bottom", "left", "right", "splitH", "splitV"};
	return e >= 0 && e < LC_EDGE_COUNT ? names[e] : "unknown";
}

prMALError startup(exExporterInfoRec* rec) {
	rec->fileType = kFileType;
	utf16("LineFinder Analysis", rec->fileTypeName);
	utf16("json", rec->fileTypeDefaultExtension);
	rec->classID = kFileType;
	rec->exportReqIndex = 0;
	rec->wantsNoProgressBar = kPrFalse;
	rec->hideInUI = kPrTrue;  // only the panel uses this format; it stays out of the Export menu
	rec->doesNotSupportAudioOnly = kPrTrue;
	rec->canExportVideo = kPrTrue;
	rec->canExportAudio = kPrFalse;
	rec->singleFrameOnly = kPrFalse;
	rec->canConformToMatchParams = kPrTrue;
	rec->interfaceVersion = EXPORTMOD_VERSION;
	return malNoError;
}

prMALError beginInstance(exportStdParms* std, exExporterInstanceRec* rec) {
	auto* in = new Instance;
	in->spBasic = std->getSPBasicSuite();
	acquire(in->spBasic, kPrSDKExportParamSuite, kPrSDKExportParamSuiteVersion, in->params);
	acquire(in->spBasic, kPrSDKExportInfoSuite, kPrSDKExportInfoSuiteVersion, in->info);
	acquire(in->spBasic, kPrSDKExportFileSuite, kPrSDKExportFileSuiteVersion, in->file);
	acquire(in->spBasic, kPrSDKExporterUtilitySuite, kPrSDKExporterUtilitySuiteVersion, in->utility);
	acquire(in->spBasic, kPrSDKPPixSuite, kPrSDKPPixSuiteVersion, in->ppix);
	acquire(in->spBasic, kPrSDKTimeSuite, kPrSDKTimeSuiteVersion, in->time);
	rec->privateData = in;
	return malNoError;
}

prMALError endInstance(exExporterInstanceRec* rec) {
	auto* in = static_cast<Instance*>(rec->privateData);
	if (!in) return malNoError;
	auto release = [&](void* suite, const char* name, int version) { if (suite) in->spBasic->ReleaseSuite(name, version); };
	release(in->params, kPrSDKExportParamSuite, kPrSDKExportParamSuiteVersion);
	release(in->info, kPrSDKExportInfoSuite, kPrSDKExportInfoSuiteVersion);
	release(in->file, kPrSDKExportFileSuite, kPrSDKExportFileSuiteVersion);
	release(in->utility, kPrSDKExporterUtilitySuite, kPrSDKExporterUtilitySuiteVersion);
	release(in->ppix, kPrSDKPPixSuite, kPrSDKPPixSuiteVersion);
	release(in->time, kPrSDKTimeSuite, kPrSDKTimeSuiteVersion);
	delete in;
	rec->privateData = nullptr;
	return malNoError;
}

void addParam(Instance* in, csSDK_uint32 id, csSDK_int32 group, const char* identifier, exParamType type, const exParamValues& values) {
	exNewParamInfo p = {};
	p.structVersion = 1;
	std::snprintf(p.identifier, sizeof(p.identifier), "%s", identifier);
	p.paramType = type;
	p.flags = exParamFlag_none;
	p.paramValues = values;
	in->params->AddParam(id, group, ADBEBasicVideoGroup, &p);
}

// Video params mirror the sequence. They only matter for the Export dialog: renders always use the sequence's own
// size and rate (queryOutputSettings), so a preset saved from one sequence works on any other.
prMALError generateDefaultParams(exGenerateDefaultParamRec* rec) {
	auto* in = static_cast<Instance*>(rec->privateData);
	const csSDK_uint32 id = rec->exporterPluginID;
	PrParam width = {}, height = {}, rate = {}, parNum = {}, parDen = {}, field = {};
	in->info->GetExportSourceInfo(id, kExportInfo_VideoWidth, &width);
	in->info->GetExportSourceInfo(id, kExportInfo_VideoHeight, &height);
	in->info->GetExportSourceInfo(id, kExportInfo_VideoFrameRate, &rate);
	in->info->GetExportSourceInfo(id, kExportInfo_PixelAspectNumerator, &parNum);
	in->info->GetExportSourceInfo(id, kExportInfo_PixelAspectDenominator, &parDen);
	in->info->GetExportSourceInfo(id, kExportInfo_VideoFieldType, &field);
	// AME initialises exporters with a 0×0 dummy sequence.
	if (width.mInt32 == 0) width.mInt32 = 1920;
	if (height.mInt32 == 0) height.mInt32 = 1080;
	if (parNum.mInt32 == 0 || parDen.mInt32 == 0) parNum.mInt32 = parDen.mInt32 = 1;

	csSDK_int32 group = 0;
	prUTF16Char name[256];
	in->params->AddMultiGroup(id, &group);
	utf16("Video", name);
	in->params->AddParamGroup(id, group, ADBETopParamGroup, ADBEVideoTabGroup, name, kPrFalse, kPrFalse, kPrFalse);
	utf16("Basic Video Settings", name);
	in->params->AddParamGroup(id, group, ADBEVideoTabGroup, ADBEBasicVideoGroup, name, kPrFalse, kPrFalse, kPrFalse);

	exParamValues v = {};
	v.structVersion = 1;
	v.rangeMin.intValue = 16; v.rangeMax.intValue = 16384;
	v.value.intValue = width.mInt32;
	addParam(in, id, group, ADBEVideoWidth, exParamType_int, v);
	v.value.intValue = height.mInt32;
	addParam(in, id, group, ADBEVideoHeight, exParamType_int, v);

	v = {};
	v.structVersion = 1;
	v.rangeMin.ratioValue = {1, 10}; v.rangeMax.ratioValue = {10, 1};
	v.value.ratioValue = {parNum.mInt32, parDen.mInt32};
	addParam(in, id, group, ADBEVideoAspect, exParamType_ratio, v);

	v = {};
	v.structVersion = 1;
	v.rangeMin.timeValue = 1;
	in->time->GetTicksPerSecond(&v.rangeMax.timeValue);
	v.value.timeValue = rate.mInt64;
	addParam(in, id, group, ADBEVideoFPS, exParamType_ticksFrameRate, v);

	v = {};
	v.structVersion = 1;
	v.value.intValue = field.mInt32;
	addParam(in, id, group, ADBEVideoFieldType, exParamType_int, v);

	in->params->SetParamsVersion(id, 1);
	return malNoError;
}

prMALError postProcessParams(exPostProcessParamsRec* rec) {
	auto* in = static_cast<Instance*>(rec->privateData);
	const csSDK_uint32 id = rec->exporterPluginID;
	const char* names[][2] = {
		{ADBEVideoTabGroup, "Video"}, {ADBEBasicVideoGroup, "Basic Video Settings"},
		{ADBEVideoWidth, "Width"}, {ADBEVideoHeight, "Height"}, {ADBEVideoAspect, "Pixel Aspect Ratio"},
		{ADBEVideoFPS, "Frame Rate"}, {ADBEVideoFieldType, "Field Order"},
	};
	prUTF16Char name[256];
	for (auto& n : names) {
		utf16(n[1], name);
		in->params->SetParamName(id, 0, n[0], name);
	}
	return malNoError;
}

// Frames are analysed at the sequence's own size and rate; the preset's values are only a fallback.
prMALError queryOutputSettings(exQueryOutputSettingsRec* rec) {
	auto* in = static_cast<Instance*>(rec->privateData);
	const csSDK_uint32 id = rec->exporterPluginID;
	const csSDK_int32 group = rec->inMultiGroupIndex;
	exParamValues width, height, rate, par, field;
	in->params->GetParamValue(id, group, ADBEVideoWidth, &width);
	in->params->GetParamValue(id, group, ADBEVideoHeight, &height);
	in->params->GetParamValue(id, group, ADBEVideoFPS, &rate);
	in->params->GetParamValue(id, group, ADBEVideoAspect, &par);
	in->params->GetParamValue(id, group, ADBEVideoFieldType, &field);
	PrParam seqWidth = {}, seqHeight = {}, seqRate = {}, seqParNum = {}, seqParDen = {}, seqField = {};
	in->info->GetExportSourceInfo(id, kExportInfo_VideoWidth, &seqWidth);
	in->info->GetExportSourceInfo(id, kExportInfo_VideoHeight, &seqHeight);
	in->info->GetExportSourceInfo(id, kExportInfo_VideoFrameRate, &seqRate);
	in->info->GetExportSourceInfo(id, kExportInfo_PixelAspectNumerator, &seqParNum);
	in->info->GetExportSourceInfo(id, kExportInfo_PixelAspectDenominator, &seqParDen);
	in->info->GetExportSourceInfo(id, kExportInfo_VideoFieldType, &seqField);
	const bool fromSequence = seqWidth.mInt32 > 0 && seqHeight.mInt32 > 0 && seqRate.mInt64 > 0;
	rec->outVideoWidth = fromSequence ? seqWidth.mInt32 : width.value.intValue;
	rec->outVideoHeight = fromSequence ? seqHeight.mInt32 : height.value.intValue;
	rec->outVideoFrameRate = fromSequence ? seqRate.mInt64 : rate.value.timeValue;
	const bool seqPar = fromSequence && seqParNum.mInt32 > 0 && seqParDen.mInt32 > 0;
	rec->outVideoAspectNum = seqPar ? seqParNum.mInt32 : par.value.ratioValue.numerator;
	rec->outVideoAspectDen = seqPar ? seqParDen.mInt32 : par.value.ratioValue.denominator;
	rec->outVideoFieldType = fromSequence ? seqField.mInt32 : field.value.intValue;
	rec->outBitratePerSecond = 0;
	return malNoError;
}

void writeProgress(Scan* scan, bool force) {
	auto now = Clock::now();
	{
		std::lock_guard<std::mutex> g(scan->lock);
		if (!force && now - scan->lastProgress < std::chrono::milliseconds(250)) return;
		scan->lastProgress = now;
	}
	if (FILE* f = openFile(scan->progressPath, "w")) {
		std::fprintf(f, "%llu %llu\n", static_cast<unsigned long long>(scan->frames.load()),
		             static_cast<unsigned long long>(scan->total));
		std::fclose(f);
	}
	if (FILE* f = openFile(scan->cancelPath, "r")) {
		std::fclose(f);
		scan->cancelled = true;
	}
}

prSuiteError onFrame(csSDK_uint32, csSDK_uint32 frameNumber, csSDK_uint32 repeatCount, PPixHand frame, void* data) {
	auto* scan = static_cast<Scan*>(data);
	Instance* in = scan->instance;
	prRect bounds = {};
	csSDK_int32 rowBytes = 0;
	PrPixelFormat format = PrPixelFormat_Invalid;
	char* pixels = nullptr;
	in->ppix->GetBounds(frame, &bounds);
	in->ppix->GetRowBytes(frame, &rowBytes);
	in->ppix->GetPixelFormat(frame, &format);
	in->ppix->GetPixels(frame, PrPPixBufferAccess_ReadOnly, &pixels);
	const int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;

	if (scan->rendered.fetch_add(1) == 0) {
		scan->width = width;
		scan->height = height;
		scan->format = format;
	}
	if (pixels && format == PrPixelFormat_BGRA_4444_8u && width > 0 && height > 0) {
		// Uncompressed PPix have a lower-left origin: start at the top row and walk the rows backwards.
		const auto* top = reinterpret_cast<const uint8_t*>(pixels) + static_cast<ptrdiff_t>(height - 1) * rowBytes;
		for (long long d : scan->dumpFrames) {
			if (d < frameNumber || d >= int64_t(frameNumber) + repeatCount) continue;
			char suffix[64];
			std::snprintf(suffix, sizeof(suffix), ".frame%lld.%dx%d.bgra", d, width, height);
			if (FILE* f = openFile(scan->base + suffix, "wb")) {
				for (int y = 0; y < height; ++y) std::fwrite(top - static_cast<ptrdiff_t>(y) * rowBytes, 4, size_t(width), f);
				std::fclose(f);
			}
		}
		lc_detection found[64];
		lc_detector* detector = scan->take();
		int n = lc_detector_scan(detector, top, width, height, -rowBytes, found, 64);
		scan->give(detector);
		if (n > 64) n = 64;
		if (n > 0) {
			// A held frame arrives once with repeatCount > 1: analysed once, recorded on every frame it covers.
			std::lock_guard<std::mutex> g(scan->lock);
			for (csSDK_uint32 r = 0; r < repeatCount; ++r) lc_segmenter_add(scan->segmenter, int64_t(frameNumber) + r, found, n);
		}
	}
	scan->frames += repeatCount;
	writeProgress(scan, false);
	return scan->cancelled ? exportReturn_Abort : suiteError_NoError;
}

prMALError exportFile(exDoExportRec* rec) {
	auto* in = static_cast<Instance*>(rec->privateData);
	const auto t0 = Clock::now();

	csSDK_int32 length = 0;
	in->file->GetPlatformPath(rec->fileObject, &length, nullptr);
	std::u16string path16(static_cast<size_t>(length) + 1, u'\0');
	in->file->GetPlatformPath(rec->fileObject, &length, reinterpret_cast<prUTF16Char*>(path16.data()));
	const std::string out = utf8(reinterpret_cast<const prUTF16Char*>(path16.c_str()));
	const std::string base = out.size() > 5 && out.compare(out.size() - 5, 5, ".json") == 0 ? out.substr(0, out.size() - 5) : out;

	PrParam rate = {};
	in->info->GetExportSourceInfo(rec->exporterPluginID, kExportInfo_VideoFrameRate, &rate);
	exParamValues paramRate;
	in->params->GetParamValue(rec->exporterPluginID, 0, ADBEVideoFPS, &paramRate);
	const PrTime ticksPerFrame = rate.mInt64 > 0 ? rate.mInt64 : paramRate.value.timeValue;

	Scan scan;
	scan.instance = in;
	scan.settings = readSettings(base + ".settings.json");
	scan.segmenter = lc_segmenter_create(scan.settings.persistence_frames);
	scan.progressPath = base + ".progress";
	scan.cancelPath = base + ".cancel";
	scan.base = base;
	scan.dumpFrames = readDumpFrames(base + ".settings.json");
	removeFile(scan.cancelPath);
	scan.total = ticksPerFrame > 0 ? static_cast<csSDK_uint64>((rec->endTime - rec->startTime) / ticksPerFrame) : 0;
	writeProgress(&scan, true);

	prSuiteError result = suiteError_NoError;
	if (rec->exportVideo) {
		ExportLoopRenderParams render = {};
		render.inRenderParamsSize = sizeof(render);
		render.inRenderParamsVersion = 1;
		render.inFinalPixelFormat = PrPixelFormat_BGRA_4444_8u;
		render.inStartTime = rec->startTime;
		render.inEndTime = rec->endTime;
		render.inHardwareResidentFrameOutputSupported = false;
		result = in->utility->DoMultiPassExportLoop(rec->exporterPluginID, &render, 1, onFrame, &scan);
	}
	writeProgress(&scan, true);
	const double seconds = std::chrono::duration<double>(Clock::now() - t0).count();

	std::vector<lc_segment> segments(static_cast<size_t>(lc_segmenter_finish(scan.segmenter, nullptr, 0)));
	lc_segmenter_finish(scan.segmenter, segments.data(), static_cast<int>(segments.size()));
	lc_segmenter_destroy(scan.segmenter);

	FILE* f = openFile(out, "w");
	if (!f) return exportReturn_ErrOpenErr;
	const bool aborted = scan.cancelled || result == exportReturn_Abort || result == suiteError_CompilerCompileAbort;
	char format[5] = {char(scan.format), char(scan.format >> 8), char(scan.format >> 16), char(scan.format >> 24), 0};
	std::fprintf(f,
		"{\"version\": 1, \"frames\": %llu, \"rendered\": %llu, \"width\": %d, \"height\": %d, \"pixelFormat\": \"%s\", "
		"\"seconds\": %.3f, \"aborted\": %s, \"result\": %d, \"startTicks\": \"%lld\", \"endTicks\": \"%lld\", "
		"\"ticksPerFrame\": \"%lld\", \"target\": \"#%02X%02X%02X\", \"anyColor\": %s, \"splits\": %s, \"segments\": [",
		static_cast<unsigned long long>(scan.frames.load()), static_cast<unsigned long long>(scan.rendered.load()),
		scan.width, scan.height, format, seconds, aborted ? "true" : "false", static_cast<int>(result),
		static_cast<long long>(rec->startTime), static_cast<long long>(rec->endTime), static_cast<long long>(ticksPerFrame),
		scan.settings.target_r, scan.settings.target_g, scan.settings.target_b,
		scan.settings.any_color ? "true" : "false", scan.settings.scan_splits ? "true" : "false");
	for (size_t i = 0; i < segments.size(); ++i) {
		const lc_segment& s = segments[i];
		std::fprintf(f, "%s\n  {\"start\": %lld, \"end\": %lld, \"edge\": \"%s\", \"thickness\": %d, \"color\": \"#%02X%02X%02X\", "
		             "\"offColor\": %s, \"position\": %d}",
		             i ? "," : "", static_cast<long long>(s.start_frame), static_cast<long long>(s.end_frame), edgeName(s.edge),
		             s.avg_thickness, s.r, s.g, s.b, s.is_off_color ? "true" : "false", s.position);
	}
	std::fprintf(f, "%s]}\n", segments.empty() ? "" : "\n");
	std::fclose(f);
	removeFile(scan.progressPath);
	removeFile(scan.cancelPath);
	// A cancelled scan still reports what it found so far: the panel shows it as stopped early.
	return scan.cancelled || result == suiteError_NoError ? malNoError : static_cast<prMALError>(result);
}

}  // namespace

extern "C" DllExport PREMPLUGENTRY xSDKExport(csSDK_int32 selector, exportStdParms* std, void* param1, void*) {
	switch (selector) {
		case exSelStartup: return startup(static_cast<exExporterInfoRec*>(param1));
		case exSelBeginInstance: return beginInstance(std, static_cast<exExporterInstanceRec*>(param1));
		case exSelEndInstance: return endInstance(static_cast<exExporterInstanceRec*>(param1));
		case exSelGenerateDefaultParams: return generateDefaultParams(static_cast<exGenerateDefaultParamRec*>(param1));
		case exSelPostProcessParams: return postProcessParams(static_cast<exPostProcessParamsRec*>(param1));
		case exSelQueryOutputSettings: return queryOutputSettings(static_cast<exQueryOutputSettingsRec*>(param1));
		case exSelQueryExportFileExtension:
			utf16("json", static_cast<exQueryExportFileExtensionRec*>(param1)->outFileExtension);
			return malNoError;
		case exSelValidateOutputSettings: return malNoError;
		case exSelExport: return exportFile(static_cast<exDoExportRec*>(param1));
		default: return exportReturn_Unsupported;
	}
}
