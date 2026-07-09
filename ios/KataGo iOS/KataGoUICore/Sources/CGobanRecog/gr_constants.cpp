//
//  gr_constants.cpp
//  CGobanRecog
//
//  Import-time constants (rule 8): function-local `static const` built on
//  first use. ports detect.py:516-517 (_KER) and stones.py:26-33 (_NODE_OFFSETS).
//

#include "gr_constants.h"

#include <algorithm>
#include <utility>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>  // getStructuringElement

namespace gobanrecog {

// ports detect.py:516-517
//   _KER = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2*_R+1, 2*_R+1)).astype(np.float32)
//   _KER /= _KER.sum()
const cv::Mat& stoneKernel() {
    static const cv::Mat kernel = [] {
        cv::Mat k8 = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * R + 1, 2 * R + 1));
        cv::Mat kf;
        k8.convertTo(kf, CV_32F);
        kf /= cv::sum(kf)[0];  // normalize to sum 1 (all nonzero cells are 1.0f)
        return kf;
    }();
    return kernel;
}

// ports stones.py:26-33
//   _NODE_OFFSETS = sorted(
//       ((dx, dy) for dx in (-0.25,-0.125,0.0,0.125,0.25)
//                 for dy in (-0.25,-0.125,0.0,0.125,0.25)),
//       key=lambda o: o[0]*o[0] + o[1]*o[1])
// Python's sorted() is STABLE; the generator emits with dx as the OUTER loop
// and dy inner. std::stable_sort over that same emission order reproduces the
// exact tie ordering (center first).
const std::vector<std::pair<double, double>>& nodeOffsets() {
    static const std::vector<std::pair<double, double>> offsets = [] {
        const double vals[5] = {-0.25, -0.125, 0.0, 0.125, 0.25};
        std::vector<std::pair<double, double>> v;
        v.reserve(25);
        for (double dx : vals) {       // dx OUTER (matches the generator)
            for (double dy : vals) {   // dy inner
                v.emplace_back(dx, dy);
            }
        }
        std::stable_sort(v.begin(), v.end(),
                         [](const std::pair<double, double>& a,
                            const std::pair<double, double>& b) {
                             return (a.first * a.first + a.second * a.second) <
                                    (b.first * b.first + b.second * b.second);
                         });
        return v;
    }();
    return offsets;
}

}  // namespace gobanrecog
