/* linecore: QCpie's Line Finder v2 (Sources/VideoQCLib/EdgeDetector.swift) in portable C++17 behind a C API.
 * Detector: one BGRA 8-bit frame in, line detections out; no allocations once warmed up (one detector per thread).
 * Segmenter: per-frame detections in, persistence-gated segments out (LineHysteresis + VideoQCResult segments).
 * Build with floating-point contraction off (-ffp-contract=off, MSVC /fp:precise) so results match the Swift detector. */
#ifndef LINECORE_H
#define LINECORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	LC_EDGE_TOP = 0,
	LC_EDGE_BOTTOM,
	LC_EDGE_LEFT,
	LC_EDGE_RIGHT,
	LC_EDGE_SPLIT_H,
	LC_EDGE_SPLIT_V,
	LC_EDGE_COUNT
} lc_edge;

/* Mirrors QCConfig; lc_settings_default() gives QCpie's defaults. */
typedef struct {
	uint8_t target_r, target_g, target_b;
	int any_color;               /* target = median colour of each candidate line */
	double sensitivity;          /* 0...1 */
	double tolerance;            /* colour distance for frame-wide suppression */
	int edge_depth;
	double min_span_ratio;
	int scan_splits;             /* internal split-screen seams */
	int report_off_color;
	int persistence_frames;      /* weak lines must hold this many consecutive frames */
	int exposure_boost;          /* black target */
	int ignore_full_black;
	int highlight_expansion;     /* white target */
	int ignore_full_white;
} lc_settings;

typedef struct {
	lc_edge edge;
	int thickness;
	uint8_t r, g, b;             /* average colour of the line */
	double span_ratio;
	double score;                /* median blend factor alpha */
	int is_weak;
	int is_off_color;
	int position;                /* seams: first row/column; edges: letterbox bar depth; -1 = none */
} lc_detection;

typedef struct {
	int64_t start_frame, end_frame;  /* inclusive */
	lc_edge edge;
	int avg_thickness;
	uint8_t r, g, b;
	int is_off_color;            /* every frame of the segment is off-colour */
	int position;
} lc_segment;

typedef struct lc_detector lc_detector;
typedef struct lc_segmenter lc_segmenter;

lc_settings lc_settings_default(void);

lc_detector* lc_detector_create(const lc_settings* settings);
void lc_detector_destroy(lc_detector* detector);
/* Returns the number of detections (at most 4 edges + any number of seams); writes up to max_out of them. */
int lc_detector_scan(lc_detector* detector, const uint8_t* bgra, int width, int height, int row_bytes,
                     lc_detection* out, int max_out);

lc_segmenter* lc_segmenter_create(int persistence_frames);
void lc_segmenter_destroy(lc_segmenter* segmenter);
/* Frames may come in any order; frames without detections need not be added. */
void lc_segmenter_add(lc_segmenter* segmenter, int64_t frame_index, const lc_detection* detections, int count);
/* Applies persistence gating and groups frames into segments; returns the count, writes up to max_out. */
int lc_segmenter_finish(lc_segmenter* segmenter, lc_segment* out, int max_out);

#ifdef __cplusplus
}
#endif

#endif
