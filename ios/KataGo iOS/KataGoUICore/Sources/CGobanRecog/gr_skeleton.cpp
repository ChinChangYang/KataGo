//
//  gr_skeleton.cpp
//  CGobanRecog
//
//  Skeleton implementation of the public seam. The real recognition pipeline
//  lands in Tasks 3-9 (gr_*.cpp modules); this file only proves the target
//  builds, links against the vendored OpenCV, and runs cv:: code end-to-end on
//  every platform the app test suite touches.
//
//  Include the specific module headers rather than the opencv.hpp umbrella:
//  the umbrella references modules that are NOT vendored (3d, calib, dnn, ...).
//

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>   // cvtColor, morphologyEx, getStructuringElement,
                                 // getPerspectiveTransform, warpPerspective
#include <opencv2/geometry.hpp>  // findHomography (OpenCV 5.0 moved it here)

#include <string>
#include <vector>

#include "GobanRecogCpp.hpp"

GobanRecogResult recognizeGoban(const uint8_t* bgr, int width, int height, size_t bytesPerRow) {
    GobanRecogResult result;

    // Wrap the caller's buffer as a BGR image with the given row stride, no
    // copy. This validates the byte-buffer seam (pointer + stride crossing
    // interop) without owning the memory. The real pipeline (Tasks 3-9) will
    // consume `input`; the degenerate/empty case is guarded so the wrap is
    // always safe.
    if (bgr != nullptr && width > 0 && height > 0) {
        cv::Mat input(height, width, CV_8UC3,
                      const_cast<uint8_t*>(bgr),
                      bytesPerRow == 0 ? cv::Mat::AUTO_STEP : bytesPerRow);
        (void)input.total();  // touch it so the wrap is not optimized away
    }

    result.status = "failed:not_implemented";
    return result;
}

string gobanRecogOpenCVSmoke() {
    // Deterministic RANSAC below.
    cv::setRNGSeed(1234);

    // 1) A small synthetic BGR image (core).
    cv::Mat bgr(64, 64, CV_8UC3, cv::Scalar(30, 60, 90));
    cv::rectangle(bgr, cv::Rect(10, 10, 40, 4), cv::Scalar(200, 210, 220), cv::FILLED);

    // 2) BGR -> gray (core + imgproc).
    cv::Mat gray;
    cv::cvtColor(bgr, gray, cv::COLOR_BGR2GRAY);

    // 3) BLACKHAT morphology with a 13x1 rectangular structuring element
    //    (mirrors the pipeline's line-detection preprocessing).
    cv::Mat se = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(13, 1));
    cv::Mat blackhat;
    cv::morphologyEx(gray, blackhat, cv::MORPH_BLACKHAT, se);

    // 4) getPerspectiveTransform + warpPerspective round trip (imgproc).
    cv::Point2f src[4] = { {0.f, 0.f}, {63.f, 0.f}, {63.f, 63.f}, {0.f, 63.f} };
    cv::Point2f dst[4] = { {5.f, 5.f}, {60.f, 2.f}, {58.f, 60.f}, {2.f, 58.f} };
    cv::Mat M = cv::getPerspectiveTransform(src, dst);
    cv::Mat warped;
    cv::warpPerspective(bgr, warped, M, bgr.size());

    // 5) findHomography(RANSAC) on synthetic correspondences with 2 gross
    //    outliers (geometry module + its usac link dependency). A known mild
    //    perspective H0 maps the source points; RANSAC must recover it and
    //    reject the two poisoned pairs.
    const cv::Matx33d H0(1.0,  0.02, 5.0,
                         0.01, 1.0,  3.0,
                         1e-4, 2e-4, 1.0);
    std::vector<cv::Point2f> pts, proj;
    for (int i = 0; i < 20; ++i) {
        cv::Point2f p(static_cast<float>((i * 7) % 60 + 2),
                      static_cast<float>((i * 11) % 60 + 2));
        const double w = H0(2, 0) * p.x + H0(2, 1) * p.y + H0(2, 2);
        const double x = (H0(0, 0) * p.x + H0(0, 1) * p.y + H0(0, 2)) / w;
        const double y = (H0(1, 0) * p.x + H0(1, 1) * p.y + H0(1, 2)) / w;
        pts.push_back(p);
        proj.push_back(cv::Point2f(static_cast<float>(x), static_cast<float>(y)));
    }
    // Poison two correspondences well beyond the 3px inlier threshold.
    proj[3] += cv::Point2f(40.f, -35.f);
    proj[11] += cv::Point2f(-30.f, 25.f);

    cv::Mat mask;
    cv::Mat H = cv::findHomography(pts, proj, cv::RANSAC, 3.0, mask);

    const int inliers = mask.empty() ? 0 : cv::countNonZero(mask);
    const bool outliers_rejected =
        !mask.empty() && mask.at<uchar>(3) == 0 && mask.at<uchar>(11) == 0;
    const bool h_ok = !H.empty()
        && inliers >= static_cast<int>(pts.size()) - 4  // most points inlier
        && outliers_rejected;

    // Touch the earlier stages so none is optimized away.
    const bool stages_ok =
        !gray.empty() && !blackhat.empty() && !warped.empty() && !M.empty();

    const std::string flag = (h_ok && stages_ok) ? "1" : "0";
    return std::string(CV_VERSION) + "|h_ok=" + flag;
}
