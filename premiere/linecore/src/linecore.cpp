// Port of Sources/VideoQCLib/EdgeDetector.swift (Line Finder v2) and the hysteresis / segment grouping of
// DetectionModels.swift. Keep the arithmetic in the same order as the Swift code: the parity harness
// (linecore/tests) compares both on every frame.

#include "linecore.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <map>
#include <set>
#include <vector>

namespace {

struct V3 {
	float x = 0, y = 0, z = 0;
};
inline V3 operator+(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline V3 operator-(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline V3 operator*(V3 a, V3 b) { return {a.x * b.x, a.y * b.y, a.z * b.z}; }
inline V3 operator*(float s, V3 a) { return {s * a.x, s * a.y, s * a.z}; }
inline V3 operator*(V3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline float sum(V3 a) { return a.x + a.y + a.z; }
inline V3 vmin(V3 a, V3 b) { return {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)}; }
inline V3 vmax(V3 a, V3 b) { return {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)}; }
inline float vmaxElement(V3 a) { return std::max(a.x, std::max(a.y, a.z)); }

struct I3 {
	long long x = 0, y = 0, z = 0;
};

constexpr int8_t kPass = 1;
constexpr int8_t kOffColor = 2;
constexpr int8_t kFail = -1;
constexpr int8_t kSkip = 0;
constexpr float kColorResidualRatio = 0.5f;
constexpr float kNoiseFloor = 24;
constexpr float kMinContrast = 40;
constexpr float kMaxAlpha = 1.35f;
constexpr int kMaxGap = 8;
constexpr float kMaxInnerAlphaRatio = 0.6f;
constexpr float kAnyColorMinAlpha = 0.6f;
constexpr int kThickLineMargin = 16;

struct Frame {
	const uint8_t* ptr;
	int width, height;
	ptrdiff_t bytesPerRow;
};

// One row/column of positions along an edge (or a seam), addressed in bytes.
struct LineWalk {
	ptrdiff_t origin, depthStride, positionStride;
	int length;
};

struct LineRun {
	int start = 0, end = -1, passes = 0, fails = 0;
	int length() const { return end - start + 1; }
};

struct Classified {
	int8_t state;
	float alpha;
};

struct BandResult {
	bool found = false;
	lc_detection line{};
	bool reachesEnd = false;
};

LineRun longestRun(const int8_t* states, int count, bool includeOffColor) {
	LineRun best, current;
	bool inRun = false;
	int pendingFails = 0;
	auto finish = [&] {
		if (current.passes > best.passes && current.passes * 4 >= (current.passes + current.fails) * 3) best = current;
		inRun = false;
		pendingFails = 0;
	};
	for (int i = 0; i < count; ++i) {
		int8_t state = states[i];
		if (state == kOffColor) state = includeOffColor ? kPass : kFail;
		if (state == kPass) {
			if (inRun) {
				current.passes += 1;
				current.fails += pendingFails;
				current.end = i;
			} else {
				current = LineRun{i, i, 1, 0};
				inRun = true;
			}
			pendingFails = 0;
		} else if (state == kFail) {
			if (!inRun) continue;
			pendingFails += 1;
			if (pendingFails > kMaxGap) finish();
		}
	}
	if (inRun) finish();
	return best;
}

float median(std::vector<float>& values) {
	if (values.empty()) return 0;
	auto mid = values.begin() + static_cast<ptrdiff_t>(values.size() / 2);
	std::nth_element(values.begin(), mid, values.end());
	return *mid;
}

bool isBlack(const lc_settings& s) { return s.target_r <= 15 && s.target_g <= 15 && s.target_b <= 15; }
bool isWhite(const lc_settings& s) { return s.target_r >= 240 && s.target_g >= 240 && s.target_b >= 240; }
double strongAlphaOf(const lc_settings& s) { return 0.45 - 0.35 * std::min(1.0, std::max(0.0, s.sensitivity)); }
double maxDistanceOf(const lc_settings& s) {
	if ((isBlack(s) && s.exposure_boost) || (isWhite(s) && s.highlight_expansion))
		return std::min(441.67 * s.tolerance, 441.67 * 0.05);
	return 441.67 * s.tolerance;
}

}  // namespace

struct lc_detector {
	lc_settings settings;
	float lut[256];
	bool hasTarget;
	V3 target;
	float weakAlpha, strongAlpha, splitMinAlpha;
	int edgeDepth;
	double minSpanRatio;
	bool reportOffColor;

	// Scratch, reused across frames.
	std::vector<V3> refs, targets;
	std::vector<int8_t> states;
	std::vector<float> alphas, lineAlphas, edgeAlphas, innerAlphas, mr, mg, mb;
	std::vector<LineRun> runs;
	std::vector<lc_detection> detections;

	explicit lc_detector(const lc_settings& s) : settings(s) {
		for (int i = 0; i < 256; ++i) lut[i] = static_cast<float>(i);
		if (!s.any_color && isBlack(s) && s.exposure_boost) {
			// Shadow expansion: separates render black from dark picture without clipping bright content.
			for (int i = 0; i < 256; ++i) lut[i] = 255 * std::sqrt(lut[i] / 255);
		} else if (!s.any_color && isWhite(s) && s.highlight_expansion) {
			for (int i = 0; i < 256; ++i) lut[i] = 255 - 255 * std::sqrt((255 - lut[i]) / 255);
		}
		hasTarget = !s.any_color;
		if (hasTarget) {
			target = {lut[s.target_r], lut[s.target_g], lut[s.target_b]};
			strongAlpha = static_cast<float>(strongAlphaOf(s));
			weakAlpha = static_cast<float>(strongAlphaOf(s) * 0.7);
		} else {
			weakAlpha = strongAlpha = kAnyColorMinAlpha;
		}
		edgeDepth = s.edge_depth;
		minSpanRatio = s.min_span_ratio;
		reportOffColor = s.report_off_color && !s.any_color;
		bool hueless = !s.any_color && (isBlack(s) || isWhite(s));
		splitMinAlpha = hueless ? std::max(weakAlpha, 0.6f) : weakAlpha;
	}

	V3 color(const uint8_t* p, ptrdiff_t o) const { return {lut[p[o + 2]], lut[p[o + 1]], lut[p[o]]}; }
	static I3 rawColor(const uint8_t* p, ptrdiff_t o) { return {p[o + 2], p[o + 1], p[o]}; }

	// alpha = ((P - R).(T - R)) / |T - R|^2, residual = |P - R - alpha(T - R)|.
	Classified classify(V3 p, V3 r, V3 t) const {
		V3 tr = t - r;
		float contrastSq = sum(tr * tr);
		if (contrastSq < kMinContrast * kMinContrast) return {kSkip, 0};
		V3 pr = p - r;
		float alpha = sum(pr * tr) / contrastSq;
		if (!(alpha >= weakAlpha && alpha <= kMaxAlpha)) return {kFail, alpha};
		V3 e = pr - alpha * tr;
		float residualSq = sum(e * e);
		float contrast = std::sqrt(contrastSq);
		float strict = std::max(kNoiseFloor, kColorResidualRatio * alpha * contrast);
		if (residualSq <= strict * strict) return {kPass, alpha};
		float loose = std::max(kNoiseFloor, 0.3f * contrast);
		return {residualSq <= loose * loose ? kOffColor : kFail, alpha};
	}

	static V3 median4(V3 a, V3 b, V3 c, V3 d) {
		V3 lo = vmin(vmin(a, b), vmin(c, d));
		V3 hi = vmax(vmax(a, b), vmax(c, d));
		return (a + b + c + d - lo - hi) * 0.5f;
	}

	// "Any colour" target: per-channel median of the candidate line (from <= 256 evenly spaced samples).
	V3 medianColor(const uint8_t* ptr, ptrdiff_t origin, ptrdiff_t stride, int count) {
		int step = std::max(1, count / 256);
		mr.clear(); mg.clear(); mb.clear();
		for (int i = 0; i < count; i += step) {
			V3 c = color(ptr, origin + i * stride);
			mr.push_back(c.x); mg.push_back(c.y); mb.push_back(c.z);
		}
		return {median(mr), median(mg), median(mb)};
	}

	int minimumRun(int length) const {
		return std::max(static_cast<int>(std::ceil(static_cast<double>(length) * minSpanRatio)), std::min(64, length));
	}

	// Frame-wide suppression: fades, slates, cards and chroma backdrops.
	bool isEntireFrameTargetOrDark(const Frame& f) const {
		const int gridDim = 12;
		int minX = static_cast<int>(f.width * 0.05), maxX = static_cast<int>(f.width * 0.95);
		int minY = static_cast<int>(f.height * 0.05), maxY = static_cast<int>(f.height * 0.95);
		int stepX = std::max(1, (maxX - minX) / (gridDim - 1));
		int stepY = std::max(1, (maxY - minY) / (gridDim - 1));
		bool black = isBlack(settings), white = isWhite(settings);
		int tr = settings.target_r, tg = settings.target_g, tb = settings.target_b;
		double maxDistance = maxDistanceOf(settings);
		long long maxDistSq = std::llround(maxDistance * maxDistance * 1.15);

		unsigned long long totalLum = 0;
		int dark = 0, targetSamples = 0, perimDark = 0, perimTarget = 0, perimTotal = 0, total = 0;
		for (int gy = 0; gy < gridDim; ++gy) {
			int y = minY + gy * stepY;
			if (y >= f.height) break;
			const uint8_t* row = f.ptr + y * f.bytesPerRow;
			bool perimY = gy == 0 || gy == gridDim - 1;
			for (int gx = 0; gx < gridDim; ++gx) {
				int x = minX + gx * stepX;
				if (x >= f.width) break;
				int b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
				bool perim = perimY || gx == 0 || gx == gridDim - 1;
				if (perim) perimTotal += 1;
				if (black || white) {
					int lum = (r * 299 + g * 587 + b * 114) / 1000;
					totalLum += static_cast<unsigned long long>(lum);
					if (black && lum <= 20) {
						dark += 1;
						if (perim) perimDark += 1;
					}
				}
				if (!black) {
					long long dr = r - tr, dg = g - tg, db = b - tb;
					if (dr * dr + dg * dg + db * db <= maxDistSq) {
						targetSamples += 1;
						if (perim) perimTarget += 1;
					}
				}
				total += 1;
			}
		}
		if (total == 0) return false;
		double avgLum = static_cast<double>(totalLum) / total;
		if (black) {
			double darkRatio = static_cast<double>(dark) / total;
			double perimRatio = perimTotal > 0 ? static_cast<double>(perimDark) / perimTotal : 0.0;
			return avgLum <= 6.0 || (darkRatio >= 0.75 && perimRatio >= 0.90) || darkRatio >= 0.90;
		}
		double targetRatio = static_cast<double>(targetSamples) / total;
		double perimRatio = perimTotal > 0 ? static_cast<double>(perimTarget) / perimTotal : 0.0;
		if (white) {
			if (!settings.ignore_full_white) return false;
			return avgLum >= 250.0 || (targetRatio >= 0.94 && perimRatio >= 0.94) || targetRatio >= 0.98;
		}
		return (targetRatio >= 0.80 && perimRatio >= 0.85) || targetRatio >= 0.88;
	}

	int scan(const Frame& f) {
		detections.clear();
		if (!settings.any_color) {
			bool suppress = isWhite(settings) ? settings.ignore_full_white : settings.ignore_full_black;
			if (suppress && isEntireFrameTargetOrDark(f)) return 0;
		}
		const int w = f.width, h = f.height;
		const ptrdiff_t bpr = f.bytesPerRow;
		struct EdgeSpec { lc_edge edge; LineWalk walk; int extent; };
		const EdgeSpec edges[] = {
			{LC_EDGE_BOTTOM, {(h - 1) * bpr, -bpr, 4, w}, h},
			{LC_EDGE_TOP, {0, bpr, 4, w}, h},
			{LC_EDGE_LEFT, {0, 4, bpr, h}, w},
			{LC_EDGE_RIGHT, {(w - 1) * 4, -4, bpr, h}, w},
		};
		for (const auto& e : edges) {
			lc_detection line;
			if (findEdgeLine(e.edge, e.walk, f, e.extent / 2 - 4, line)) {
				detections.push_back(line);
				continue;
			}
			// Letterbox / pillarbox: also scan where the picture starts, inside the bar. Not for a black target.
			int matte = matteThickness(f, e.walk, e.extent);
			if (matte <= edgeDepth || (hasTarget && vmaxElement(target) < 30)) continue;
			LineWalk inner{e.walk.origin + matte * e.walk.depthStride, e.walk.depthStride, e.walk.positionStride, e.walk.length};
			if (findEdgeLine(e.edge, inner, f, (e.extent - 2 * matte) / 2 - 4, line)) {
				line.position = matte;
				detections.push_back(line);
			}
		}
		if (settings.scan_splits) {
			scanSplits(LC_EDGE_SPLIT_H, f);
			scanSplits(LC_EDGE_SPLIT_V, f);
		}
		return static_cast<int>(detections.size());
	}

	// A line starting within edgeDepth of the edge; thicker ones only when a band fills the whole scan depth.
	bool findEdgeLine(lc_edge edge, const LineWalk& walk, const Frame& f, int maxDepth, lc_detection& out) {
		int depthCount = std::min(edgeDepth, maxDepth);
		if (depthCount < 1) return false;
		BandResult first = scanEdge(edge, walk, f, depthCount, depthCount);
		if (first.found) { out = first.line; return true; }
		int deepCount = std::min(edgeDepth + kThickLineMargin, maxDepth);
		if (!first.reachesEnd || deepCount <= depthCount) return false;
		BandResult deep = scanEdge(edge, walk, f, deepCount, depthCount);
		if (deep.found) out = deep.line;
		return deep.found;
	}

	BandResult scanEdge(lc_edge edge, const LineWalk& walk, const Frame& f, int depthCount, int maxStart) {
		const int n = walk.length;
		const uint8_t* ptr = f.ptr;
		const int minRun = minimumRun(n);
		// R(p): median of the 4 depths just past the scanned band.
		refs.resize(static_cast<size_t>(n));
		for (int p = 0; p < n; ++p) {
			ptrdiff_t o = walk.origin + p * walk.positionStride + depthCount * walk.depthStride;
			refs[p] = median4(color(ptr, o), color(ptr, o + walk.depthStride), color(ptr, o + 2 * walk.depthStride),
			                  color(ptr, o + 3 * walk.depthStride));
		}
		states.assign(static_cast<size_t>(n) * depthCount, kSkip);
		alphas.assign(static_cast<size_t>(n) * depthCount, 0.f);
		targets.clear();
		// Every depth is judged on its own: a line 1 px in, behind a half-blended outer row, still counts.
		for (int d = 0; d < depthCount; ++d) {
			ptrdiff_t rowOrigin = walk.origin + d * walk.depthStride;
			V3 t = hasTarget ? target : medianColor(ptr, rowOrigin, walk.positionStride, n);
			targets.push_back(t);
			for (int p = 0; p < n; ++p) {
				Classified c = classify(color(ptr, rowOrigin + p * walk.positionStride), refs[p], t);
				states[static_cast<size_t>(d) * n + p] = c.state;
				alphas[static_cast<size_t>(d) * n + p] = c.alpha;
			}
		}
		BandResult onTarget = bestBand(edge, walk, ptr, depthCount, maxStart, minRun, false);
		if (onTarget.found || !reportOffColor) return onTarget;
		BandResult off = bestBand(edge, walk, ptr, depthCount, maxStart, minRun, true);
		off.reachesEnd = onTarget.reachesEnd || off.reachesEnd;
		return off;
	}

	// The strongest band of consecutive depths with a long run that steps back to the picture before the band ends.
	BandResult bestBand(lc_edge edge, const LineWalk& walk, const uint8_t* ptr, int depthCount, int maxStart, int minRun,
	                    bool offColor) {
		const int n = walk.length;
		runs.resize(static_cast<size_t>(depthCount));
		for (int d = 0; d < depthCount; ++d) runs[d] = longestRun(&states[static_cast<size_t>(d) * n], n, offColor);
		auto accepted = [&](int8_t s) { return s == kPass || (offColor && s == kOffColor); };
		BandResult result;
		int lo = 0;
		while (lo < maxStart) {
			if (runs[lo].passes < minRun) { lo += 1; continue; }
			int hi = lo;
			while (hi + 1 < depthCount && runs[hi + 1].passes >= minRun) hi += 1;
			const int bandLo = lo;
			lo = hi + 1;
			// Fills the scan depth: a thicker line, a letterbox / pillarbox or picture content.
			if (hi >= depthCount - 1) { result.reachesEnd = true; continue; }

			int core = bandLo;
			for (int d = bandLo + 1; d <= hi; ++d) if (runs[d].passes > runs[core].passes) core = d;
			const LineRun run = runs[core];
			const V3 t = targets[core];

			lineAlphas.clear(); edgeAlphas.clear(); innerAlphas.clear();
			I3 total;
			int passCount = 0;
			const ptrdiff_t innerOrigin = walk.origin + (hi + 1) * walk.depthStride;
			const ptrdiff_t coreOrigin = walk.origin + core * walk.depthStride;
			for (int p = run.start; p <= run.end; ++p) {
				size_t i = static_cast<size_t>(core) * n + p;
				size_t ei = static_cast<size_t>(hi) * n + p;
				if (states[i] != kSkip) lineAlphas.push_back(alphas[i]);
				if (states[ei] != kSkip) edgeAlphas.push_back(alphas[ei]);
				if (accepted(states[i])) {
					I3 c = rawColor(ptr, coreOrigin + p * walk.positionStride);
					total.x += c.x; total.y += c.y; total.z += c.z;
					passCount += 1;
				}
				Classified inner = classify(color(ptr, innerOrigin + p * walk.positionStride), refs[p], t);
				if (inner.state != kSkip) innerAlphas.push_back(inner.alpha);
			}
			float lineAlpha = median(lineAlphas);
			float innerAlpha = median(innerAlphas);
			// Step at the line's inner boundary: a gradient fades out gradually, a line stops.
			float edgeAlpha = median(edgeAlphas);
			if (passCount > 0 && lineAlpha >= weakAlpha && innerAlpha > edgeAlpha * kMaxInnerAlphaRatio && hi + 2 < depthCount) {
				// Chroma bleed: 4:2:0 chroma smeared into the next row (Premiere: saturated, darker target colour;
				// AVFoundation: a 2nd column inside a 3 px line at an odd offset). The row has the line's strength but
				// fails the strict colour test (fail with alpha in range, or off-colour). A gradient's rows still look
				// like blends. One such row counts as part of the line for the step test.
				int colourFails = 0, informative = 0;
				for (int p = run.start; p <= run.end; ++p) {
					size_t i = static_cast<size_t>(hi + 1) * n + p;
					if (states[i] == kSkip) continue;
					informative += 1;
					if (states[i] == kOffColor || (states[i] == kFail && alphas[i] >= weakAlpha && alphas[i] <= kMaxAlpha)) colourFails += 1;
				}
				if (informative > 0 && colourFails * 2 >= informative) {
					innerAlphas.clear();
					const ptrdiff_t nextOrigin = walk.origin + (hi + 2) * walk.depthStride;
					for (int p = run.start; p <= run.end; ++p) {
						Classified next = classify(color(ptr, nextOrigin + p * walk.positionStride), refs[p], t);
						if (next.state != kSkip) innerAlphas.push_back(next.alpha);
					}
					innerAlpha = median(innerAlphas);
				}
			}
			if (!(passCount > 0 && lineAlpha >= weakAlpha && innerAlpha <= edgeAlpha * kMaxInnerAlphaRatio)) continue;

			lc_detection d{};
			d.edge = edge;
			d.thickness = hi - bandLo + 1;
			d.r = static_cast<uint8_t>(total.x / passCount);
			d.g = static_cast<uint8_t>(total.y / passCount);
			d.b = static_cast<uint8_t>(total.z / passCount);
			d.span_ratio = static_cast<double>(run.length()) / n;
			d.score = static_cast<double>(lineAlpha);
			d.is_weak = offColor || lineAlpha < strongAlpha;
			d.is_off_color = offColor;
			d.position = -1;
			if (!result.found || d.score > result.line.score) {
				result.found = true;
				result.line = d;
			}
		}
		return result;
	}

	// Rows (columns) of uniform near-black bar from this edge inwards, up to 30% of the frame; 0 when there is none.
	static int matteThickness(const Frame& f, const LineWalk& walk, int extent) {
		const int samples = 48;
		int step = std::max(1, walk.length / samples);
		int depth = 0;
		while (depth < extent * 3 / 10) {
			ptrdiff_t o = walk.origin + depth * walk.depthStride;
			int lo = 255, hi = 0;
			for (int i = step / 2; i < walk.length; i += step) {
				const uint8_t* p = f.ptr + o + i * walk.positionStride;
				int luma = (p[2] * 54 + p[1] * 183 + p[0] * 19) >> 8;
				lo = std::min(lo, luma);
				hi = std::max(hi, luma);
			}
			if (!(hi <= 24 && hi - lo <= 12)) break;
			depth += 1;
		}
		return depth;
	}

	// Internal seams: each row (column) compared with the picture 2 px and edgeDepth + 1 px away on both sides,
	// sampling every 2nd pixel. Clusters thicker than edgeDepth are picture content.
	void scanSplits(lc_edge kind, const Frame& f) {
		const bool alongRows = kind == LC_EDGE_SPLIT_H;
		const int lineCount = alongRows ? f.height : f.width;
		const int positions = alongRows ? f.width : f.height;
		const ptrdiff_t lineStride = alongRows ? f.bytesPerRow : 4;
		const int step = 2;
		const ptrdiff_t positionStride = (alongRows ? 4 : f.bytesPerRow) * step;
		const int samples = (positions + step - 1) / step;
		const int minRun = std::max(1, minimumRun(positions) / step);
		const ptrdiff_t offset = (edgeDepth + 1) * lineStride;
		const ptrdiff_t nearOffset = 2 * lineStride;
		const uint8_t* ptr = f.ptr;
		// A seam pixel: a strict colour match against one side, and still a line against the other.
		auto seam = [&](V3 p, ptrdiff_t o, V3 t) -> Classified {
			float bestAlpha = 0;
			bool anySkip = false;
			for (ptrdiff_t d : {nearOffset, offset}) {
				Classified a = classify(p, color(ptr, o - d), t);
				Classified b = classify(p, color(ptr, o + d), t);
				bool aLine = a.state == kPass || a.state == kOffColor;
				bool bLine = b.state == kPass || b.state == kOffColor;
				if ((a.state == kPass && bLine) || (b.state == kPass && aLine)) return {kPass, std::min(a.alpha, b.alpha)};
				if (a.state == kSkip || b.state == kSkip) anySkip = true;
				bestAlpha = std::max(bestAlpha, std::min(a.alpha, b.alpha));
			}
			return {anySkip ? kSkip : kFail, bestAlpha};
		};
		if (lineCount <= 2 * (edgeDepth + 1)) return;

		states.assign(static_cast<size_t>(samples), kSkip);
		alphas.assign(static_cast<size_t>(samples), 0.f);
		int clusterStart = -1;
		bool hasBest = false;
		float bestAlpha = 0;
		LineRun bestRun;
		int bestLine = 0;
		V3 bestTarget;

		auto closeCluster = [&](int line) {
			if (clusterStart >= 0 && hasBest && line - clusterStart <= edgeDepth) {
				I3 total;
				int count = 0;
				for (int s = bestRun.start; s <= bestRun.end; ++s) {
					ptrdiff_t o = bestLine * lineStride + s * positionStride;
					if (seam(color(ptr, o), o, bestTarget).state == kPass) {
						I3 c = rawColor(ptr, o);
						total.x += c.x; total.y += c.y; total.z += c.z;
						count += 1;
					}
				}
				int divisor = std::max(1, count);
				lc_detection d{};
				d.edge = kind;
				d.thickness = line - clusterStart;
				d.r = static_cast<uint8_t>(total.x / divisor);
				d.g = static_cast<uint8_t>(total.y / divisor);
				d.b = static_cast<uint8_t>(total.z / divisor);
				d.span_ratio = static_cast<double>(bestRun.length()) / samples;
				d.score = static_cast<double>(bestAlpha);
				d.is_weak = bestAlpha < std::max(strongAlpha, splitMinAlpha);
				d.is_off_color = 0;
				d.position = clusterStart;
				detections.push_back(d);
			}
			clusterStart = -1;
			hasBest = false;
		};

		const int first = edgeDepth + 1;
		const int last = lineCount - edgeDepth - 1;
		// Coarse pre-check: a seam long enough to count passes on most of these sparse samples too.
		const int coarseStep = 8;
		const ptrdiff_t coarseStride = positionStride * coarseStep;
		const int coarseSamples = samples / coarseStep;
		const int coarseNeeded = std::max(2, minRun / coarseStep / 2);
		for (int line = first; line < last; ++line) {
			const ptrdiff_t lineOrigin = line * lineStride;
			const V3 t = hasTarget ? target : medianColor(ptr, lineOrigin, positionStride, samples);
			int coarsePasses = 0;
			for (int c = 0; c < coarseSamples; ++c) {
				ptrdiff_t o = lineOrigin + c * coarseStride;
				if (seam(color(ptr, o), o, t).state == kPass) coarsePasses += 1;
			}
			if (coarsePasses < coarseNeeded) {
				if (clusterStart >= 0) closeCluster(line);
				continue;
			}
			for (int s = 0; s < samples; ++s) {
				ptrdiff_t o = lineOrigin + s * positionStride;
				Classified r = seam(color(ptr, o), o, t);
				states[s] = r.state;
				alphas[s] = r.alpha;
			}
			LineRun run = longestRun(states.data(), samples, false);
			bool isCandidate = false;
			if (run.passes >= minRun) {
				lineAlphas.clear();
				for (int s = run.start; s <= run.end; ++s) if (states[s] != kSkip) lineAlphas.push_back(alphas[s]);
				float alpha = median(lineAlphas);
				if (alpha >= splitMinAlpha) {
					isCandidate = true;
					if (clusterStart < 0) clusterStart = line;
					if (!hasBest || alpha > bestAlpha) {
						hasBest = true;
						bestAlpha = alpha;
						bestRun = run;
						bestLine = line;
						bestTarget = t;
					}
				}
			}
			if (!isCandidate && clusterStart >= 0) closeCluster(line);
		}
		if (clusterStart >= 0) closeCluster(last);
	}
};

struct lc_segmenter {
	int persistence;
	std::map<int64_t, std::vector<lc_detection>> frames;
	bool finished = false;
	std::vector<lc_segment> segments;

	// Strong detections stay; weak ones only where the same edge has candidates in >= persistence consecutive frames.
	void filter() {
		std::set<int64_t> persistent[LC_EDGE_COUNT];
		for (int edge = 0; edge < LC_EDGE_COUNT; ++edge) {
			std::vector<int64_t> run;
			auto close = [&] {
				if (static_cast<int>(run.size()) >= persistence) persistent[edge].insert(run.begin(), run.end());
				run.clear();
			};
			for (const auto& [index, dets] : frames) {
				if (std::none_of(dets.begin(), dets.end(), [&](const lc_detection& d) { return d.edge == edge; })) continue;
				if (!run.empty() && index != run.back() + 1) close();
				run.push_back(index);
			}
			close();
		}
		for (auto it = frames.begin(); it != frames.end();) {
			auto& dets = it->second;
			const int64_t index = it->first;
			dets.erase(std::remove_if(dets.begin(), dets.end(), [&](const lc_detection& d) {
				return d.is_weak && !persistent[d.edge].count(index);
			}), dets.end());
			it = dets.empty() ? frames.erase(it) : std::next(it);
		}
	}

	// A segment follows one line through consecutive frames: same edge and, for seams, the same row/column (±2 px).
	void group() {
		struct Track {
			lc_edge edge;
			int64_t start, end;
			lc_detection first;
			int position;
			long long thicknessSum;
			int count;
			bool allOffColor;
			bool continues(const lc_detection& d, int64_t index) const {
				if (d.edge != edge || index != end + 1) return false;
				if (!(edge == LC_EDGE_SPLIT_H || edge == LC_EDGE_SPLIT_V) || position < 0 || d.position < 0) return true;
				return std::abs(d.position - position) <= 2;
			}
			lc_segment segment() const {
				lc_segment s{};
				s.start_frame = start;
				s.end_frame = end;
				s.edge = edge;
				s.avg_thickness = static_cast<int>(std::max<long long>(1, thicknessSum / count));
				s.r = first.r; s.g = first.g; s.b = first.b;
				s.is_off_color = allOffColor;
				s.position = first.position;
				return s;
			}
		};
		auto track = [](const lc_detection& d, int64_t index) {
			return Track{d.edge, index, index, d, d.position, d.thickness, 1, d.is_off_color != 0};
		};
		std::vector<Track> open, continued;
		for (const auto& entry : frames) {
			const int64_t index = entry.first;
			const auto& dets = entry.second;
			continued.clear();
			for (const auto& d : dets) {
				auto k = std::find_if(open.begin(), open.end(), [&](const Track& t) { return t.continues(d, index); });
				if (k != open.end()) {
					Track t = *k;
					open.erase(k);
					t.end = index;
					if (d.position >= 0) t.position = d.position;
					t.thicknessSum += d.thickness;
					t.count += 1;
					t.allOffColor = t.allOffColor && d.is_off_color;
					continued.push_back(t);
				} else {
					continued.push_back(track(d, index));
				}
			}
			for (const auto& t : open) segments.push_back(t.segment());
			open.swap(continued);
		}
		for (const auto& t : open) segments.push_back(t.segment());
		std::stable_sort(segments.begin(), segments.end(),
		                 [](const lc_segment& a, const lc_segment& b) { return a.start_frame < b.start_frame; });
	}
};

extern "C" {

lc_settings lc_settings_default(void) {
	lc_settings s{};
	s.target_r = 0; s.target_g = 255; s.target_b = 0;
	s.any_color = 0;
	s.sensitivity = 0.5;
	s.tolerance = 0.25;
	s.edge_depth = 12;
	s.min_span_ratio = 0.25;
	s.scan_splits = 0;
	s.report_off_color = 1;
	s.persistence_frames = 6;
	s.exposure_boost = 1;
	s.ignore_full_black = 1;
	s.highlight_expansion = 1;
	s.ignore_full_white = 1;
	return s;
}

lc_detector* lc_detector_create(const lc_settings* settings) { return new lc_detector(*settings); }
void lc_detector_destroy(lc_detector* detector) { delete detector; }

int lc_detector_scan(lc_detector* detector, const uint8_t* bgra, int width, int height, int row_bytes,
                     lc_detection* out, int max_out) {
	if (!detector || !bgra || width <= 0 || height <= 0) return 0;
	int n = detector->scan(Frame{bgra, width, height, row_bytes});
	for (int i = 0; i < n && i < max_out; ++i) out[i] = detector->detections[static_cast<size_t>(i)];
	return n;
}

lc_segmenter* lc_segmenter_create(int persistence_frames) {
	auto* s = new lc_segmenter;
	s->persistence = persistence_frames;
	return s;
}
void lc_segmenter_destroy(lc_segmenter* segmenter) { delete segmenter; }

void lc_segmenter_add(lc_segmenter* segmenter, int64_t frame_index, const lc_detection* detections, int count) {
	if (count <= 0 || segmenter->finished) return;
	auto& dets = segmenter->frames[frame_index];
	dets.insert(dets.end(), detections, detections + count);
}

int lc_segmenter_finish(lc_segmenter* segmenter, lc_segment* out, int max_out) {
	if (!segmenter->finished) {
		segmenter->filter();
		segmenter->group();
		segmenter->finished = true;
	}
	int n = static_cast<int>(segmenter->segments.size());
	for (int i = 0; i < n && i < max_out; ++i) out[i] = segmenter->segments[static_cast<size_t>(i)];
	return n;
}

}  // extern "C"
