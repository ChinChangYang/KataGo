//
//  gr_run.cpp
//  CGobanRecog
//
//  ports gobanrecog/pipeline/run.py::recognize_image, plus the real public
//  recognizeGoban seam (RecognitionResult -> GobanRecogResult) that Task 11's
//  GobanRecogKit calls, and the cv-free test/CLI bridges (recognize_status_line
//  / recognize_debug_json used by gobanrecog-cli + the native smoke test).
//

#pragma STDC FP_CONTRACT OFF  // belt-and-suspenders; see the target's -ffp-contract=off

#include "gr_run.h"

#include <cmath>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

#include <opencv2/core.hpp>

#include "GobanRecogCpp.hpp"        // public seam: GobanRecogResult / recognizeGoban
#include "GobanRecogTestBridge.hpp"
#include "gr_constants.h"           // CONF_FLOOR + CONF_FLOOR_RESCUE (run.py)
#include "gr_sgf.h"                 // board_to_sgf
#include "gr_stones.h"              // classify_stones, StoneClassification

namespace gobanrecog {

// ports run.py::recognize_image.
RecognitionResult recognize_image(const cv::Mat& img_bgr) {
    // Run every cv:: op single-threaded (parallel_for_ executes the body
    // inline on this thread). The vendored HAVE_PTHREADS_PF worker pool
    // (core/parallel_impl.cpp) has an upstream-acknowledged completion race
    // ("BUG! ... TODO Dbg this" in ParallelJob::execute; opencv/opencv#19463,
    // #23609 — never fixed): under scheduler pressure a late worker can touch
    // caller memory after parallel_for returns. Observed here as rare
    // nondeterministic heap corruption — libc++-hardened Debug aborts inside
    // np_percentile's std::sort ("range is not sorted after the sort") at
    // varying pipeline stages on NaN-free data; Release would corrupt
    // silently. Recognition is a one-shot background call, so the latency
    // cost is acceptable and per-run determinism improves. Thread count is
    // process-global cv state — consistent with this pipeline already being
    // documented as not concurrency-safe (global RNG seed below).
    cv::setNumThreads(0);

    // port-conventions rule 12: seed the global cv RNG EXACTLY ONCE, here at
    // recognize_image entry — the SINGLE seed for the whole pipeline.
    // detect_board does NOT seed at its own entry; its internal re-anchor
    // (detect.py:929, before the stone-lattice proposer) still applies. This is
    // the documented deviation from Python (which seeds only before the lattice
    // proposer).
    cv::setRNGSeed(1234);

    RecognitionResult result;

    BoardDetection det;
    try {
        det = detect_board(img_bgr);
    } catch (const DetectionError& e) {
        // run.py: `except DetectionError as e: return RecognitionResult(
        //          status=f"failed:{e}")`. Only DetectionError is caught here
        // (cv2.error / LinAlgError are caught INSIDE detect_board's proposers).
        result.status = std::string("failed:") + e.what();
        return result;
    }

    const StoneClassification cls = classify_stones(img_bgr, det.H_grid, det.board_size);

    // run.py merges {**det.debug, **cls.debug}; cls has no debug (== {}), so the
    // recognition debug is det.debug alone on every path below.
    //
    // Two-tier acceptance (run.py lockstep): boards the legacy rule already
    // trusted keep the plain floor; boards only the rule-3 guard lifts over
    // the floor ("rescues") must clear CONF_FLOOR_RESCUE. The middle band
    // reuses the same reason string — eval_cpp compares status strings
    // verbatim between the Python reference and this port.
    const bool accepted =
        cls.confidence >= CONF_FLOOR &&
        (cls.confidence_legacy >= CONF_FLOOR || cls.confidence >= CONF_FLOOR_RESCUE);
    if (!accepted) {
        result.status = "failed:low_confidence";
        result.confidence = cls.confidence;
        result.confidence_legacy = cls.confidence_legacy;
        result.debug = det.debug;
        return result;
    }

    result.status = "ok";
    result.board = cls.board;
    result.board_size = det.board_size;
    result.corners = det.corners;
    result.H_grid = det.H_grid;
    result.confidence = cls.confidence;
    result.confidence_legacy = cls.confidence_legacy;
    result.debug = det.debug;
    return result;
}

}  // namespace gobanrecog

// ---- Public seam (global scope; cv-free signature) -------------------------
// Translates the internal RecognitionResult to the value-semantic
// GobanRecogResult. No cv:: types cross this boundary; no named-local
// swift::Optional is ever returned (project interop landmine).
GobanRecogResult recognizeGoban(const uint8_t* bgr, int width, int height, size_t bytesPerRow) {
    GobanRecogResult out;

    if (bgr == nullptr || width <= 0 || height <= 0) {
        // Not a Python-modeled path (recognize_image always gets a real image);
        // guard the wrap and surface a loud failure the caller can branch on.
        out.status = "failed:empty image";
        return out;
    }

    // Wrap the caller's buffer as BGR with the given row stride, no copy.
    const cv::Mat input(height, width, CV_8UC3, const_cast<uint8_t*>(bgr),
                        bytesPerRow == 0 ? cv::Mat::AUTO_STEP : bytesPerRow);

    const gobanrecog::RecognitionResult r = gobanrecog::recognize_image(input);

    out.status = r.status;
    out.confidence = r.confidence;
    out.quadSource = r.debug.quad_source;
    if (r.board_size.has_value()) {
        out.boardSize = *r.board_size;
    }
    if (r.board.has_value()) {
        out.rows = r.board->rows;  // value copy of the row strings
    }
    return out;
}

// ---- test / CLI bridge (cv-free seam; see GobanRecogTestBridge.hpp) ---------
namespace gobanrecog {
namespace testbridge {

namespace {

void append_double(std::string& out, double v) {
    if (std::isnan(v)) { out += "NaN"; return; }
    if (std::isinf(v)) { out += (v > 0 ? "Infinity" : "-Infinity"); return; }
    char buf[40];
    std::snprintf(buf, sizeof(buf), "%.17g", v);
    out += buf;
}

void append_json_string(std::string& out, const std::string& s) {
    out += '"';
    for (const char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    out += '"';
}

}  // namespace

// Runs recognize_image on a raw BGR HxWx3 buffer and returns a TAB-separated
// line for the CLI (normal mode) + the native smoke test:
//   "<status>\t<board_size>\t<confidence %.17g>\t<quad_source>\t<sgf>"
// board_size = 0 when absent; sgf = "" unless status == "ok". Only the final
// field (sgf) may follow tabs, and an SGF never contains a tab or newline, so a
// split on the first four tabs is unambiguous.
std::string recognize_status_line(const unsigned char* bgr, int width, int height) {
    const cv::Mat input(height, width, CV_8UC3, const_cast<unsigned char*>(bgr));
    const RecognitionResult r = recognize_image(input);

    std::string sgf;
    if (r.status == "ok" && r.board.has_value()) {
        sgf = board_to_sgf(*r.board);
    }
    char conf[40];
    std::snprintf(conf, sizeof(conf), "%.17g", r.confidence);

    std::string out = r.status;
    out += '\t';
    out += std::to_string(r.board_size.value_or(0));
    out += '\t';
    out += conf;
    out += '\t';
    out += r.debug.quad_source;
    out += '\t';
    out += sgf;
    return out;
}

// Full recognize debug JSON for the CLI --debug-json + Task-10 drill-down. On
// failure the geometry arrays are empty and `sgf` is ""; size_scores/quad_source
// carry det.debug when a detection succeeded (low_confidence path).
std::string recognize_debug_json(const unsigned char* bgr, int width, int height) {
    const cv::Mat input(height, width, CV_8UC3, const_cast<unsigned char*>(bgr));
    const RecognitionResult r = recognize_image(input);

    std::string out;
    out.reserve(1 << 12);
    out += "{\"stage\": \"recognize\", \"status\": ";
    append_json_string(out, r.status);

    out += ", \"board_size\": ";
    if (r.board_size.has_value()) out += std::to_string(*r.board_size);
    else out += "null";

    out += ", \"quad_source\": ";
    append_json_string(out, r.debug.quad_source);

    out += ", \"confidence\": ";
    append_double(out, r.confidence);

    // run.py debug["confidence_legacy"] (two-tier acceptance drill-down)
    out += ", \"confidence_legacy\": ";
    append_double(out, r.confidence_legacy);

    out += ", \"corners\": [";
    if (!r.corners.empty()) {
        for (int k = 0; k < 4; ++k) {
            if (k) out += ", ";
            out += '[';
            append_double(out, r.corners.at<double>(k, 0));
            out += ", ";
            append_double(out, r.corners.at<double>(k, 1));
            out += ']';
        }
    }
    out += "], \"H_grid\": [";
    if (!r.H_grid.empty()) {
        for (int i = 0; i < 9; ++i) {
            if (i) out += ", ";
            append_double(out, r.H_grid.at<double>(i / 3, i % 3));
        }
    }
    out += "], \"rows\": [";
    if (r.board.has_value()) {
        const std::vector<std::string>& rows = r.board->rows;
        for (size_t i = 0; i < rows.size(); ++i) {
            if (i) out += ", ";
            append_json_string(out, rows[i]);
        }
    }
    out += "], \"size_scores\": {";
    bool first = true;
    for (const auto& kv : r.debug.size_scores) {
        if (!first) out += ", ";
        first = false;
        out += '"';
        out += std::to_string(kv.first);
        out += "\": ";
        append_double(out, kv.second);
    }
    out += "}, \"sgf\": ";
    std::string sgf;
    if (r.status == "ok" && r.board.has_value()) sgf = board_to_sgf(*r.board);
    append_json_string(out, sgf);
    out += "}";
    return out;
}

}  // namespace testbridge
}  // namespace gobanrecog
