//
//  gr_run.h
//  CGobanRecog
//
//  Ports gobanrecog/pipeline/run.py::recognize_image (the end-to-end
//  orchestration: image -> board position or loud failure). INTERNAL header
//  (uses cv:: types for corners/H_grid; kept out of include/). The public,
//  cv-free entry point is recognizeGoban in include/GobanRecogCpp.hpp (also
//  defined in gr_run.cpp).
//
//  run.py's recognize_file (imread + optional overlay + SGF write) is NOT
//  ported here — imgcodecs is not vendored, so file loading is a caller/CLI
//  concern; the gobanrecog-cli tool + the Task-11 Swift seam decode/prepare the
//  BGR buffer and call recognizeGoban.
//

#ifndef gr_run_h
#define gr_run_h

#include <optional>
#include <string>

#include <opencv2/core.hpp>

#include "gr_detect.h"  // BoardDetection, DebugInfo, DetectionError, detect_board
#include "gr_types.h"   // BoardState

namespace gobanrecog {

// ports run.py::RecognitionResult (dataclass). Python's `corners`/`H_grid` are
// `np.ndarray | None`; a default-constructed (empty) cv::Mat models None. The
// dict `debug` is a DebugInfo (rule 6): run.py merges {**det.debug, **cls.debug}
// but StoneClassification has no debug member (stones.py debug is always {}), so
// debug = det.debug.
struct RecognitionResult {
    std::string status;                 // "ok" or "failed:<reason>"
    std::optional<BoardState> board;    // None on any failure
    std::optional<int> board_size;      // None on any failure
    cv::Mat corners;                    // empty Mat == Python None
    cv::Mat H_grid;                     // empty Mat == Python None
    double confidence = 0.0;
    DebugInfo debug;
};

// ports run.py::recognize_image. img_bgr: uint8 BGR HxWx3.
RecognitionResult recognize_image(const cv::Mat& img_bgr);

}  // namespace gobanrecog

#endif /* gr_run_h */
