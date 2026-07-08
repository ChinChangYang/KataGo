// Smoke tests for the vendored OpenCV 5.0.0 package.
// Exercises the exact facilities the Go-board recognition pipeline needs:
// Mat construction, cvtColor, morphologyEx(BLACKHAT), getPerspectiveTransform,
// warpPerspective, and findHomography with RANSAC/LMEDS on noisy point pairs.

#import <XCTest/XCTest.h>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/geometry/2d.hpp>
#include <opencv2/geometry/3d.hpp>

#include <cmath>
#include <vector>

@interface SmokeTests : XCTestCase
@end

@implementation SmokeTests

- (void)testVersionString {
    XCTAssertEqualObjects(@(CV_VERSION), @"5.0.0");
}

- (void)testCvtColorAndBlackhat {
    // Synthetic BGR image: mid-gray background with a dark 4x4 square.
    cv::Mat bgr(32, 32, CV_8UC3, cv::Scalar(128, 128, 128));
    cv::rectangle(bgr, cv::Rect(12, 12, 4, 4), cv::Scalar(20, 20, 20), cv::FILLED);

    cv::Mat gray;
    cv::cvtColor(bgr, gray, cv::COLOR_BGR2GRAY);
    XCTAssertEqual(gray.type(), CV_8UC1);
    XCTAssertEqual((int)gray.at<uchar>(0, 0), 128);
    XCTAssertEqual((int)gray.at<uchar>(14, 14), 20);

    // BLACKHAT highlights dark features smaller than the structuring element.
    cv::Mat blackhat;
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(9, 9));
    cv::morphologyEx(gray, blackhat, cv::MORPH_BLACKHAT, kernel);
    XCTAssertEqual((int)blackhat.at<uchar>(14, 14), 108);  // 128 - 20
    XCTAssertEqual((int)blackhat.at<uchar>(0, 0), 0);      // flat background

    // float32 gray conversion path used by the pipeline.
    cv::Mat bgrF;
    bgr.convertTo(bgrF, CV_32FC3, 1.0 / 255.0);
    cv::Mat grayF;
    cv::cvtColor(bgrF, grayF, cv::COLOR_BGR2GRAY);
    XCTAssertEqual(grayF.type(), CV_32FC1);
    XCTAssertEqualWithAccuracy(grayF.at<float>(0, 0), 128.0f / 255.0f, 1e-5f);
}

- (void)testPerspectiveTransformRoundTrip {
    // Map the unit square corners to a skewed quad and back.
    std::vector<cv::Point2f> src = {{0, 0}, {100, 0}, {100, 100}, {0, 100}};
    std::vector<cv::Point2f> dst = {{10, 5}, {95, 12}, {88, 105}, {3, 92}};

    cv::Mat M = cv::getPerspectiveTransform(src, dst);
    XCTAssertEqual(M.rows, 3);
    XCTAssertEqual(M.cols, 3);

    std::vector<cv::Point2f> mapped;
    cv::perspectiveTransform(src, mapped, M);
    for (size_t i = 0; i < src.size(); i++) {
        XCTAssertEqualWithAccuracy(mapped[i].x, dst[i].x, 1e-3);
        XCTAssertEqualWithAccuracy(mapped[i].y, dst[i].y, 1e-3);
    }

    // warpPerspective moves a bright square where M says it should go.
    cv::Mat img = cv::Mat::zeros(120, 120, CV_8UC1);
    cv::rectangle(img, cv::Rect(40, 40, 20, 20), cv::Scalar(255), cv::FILLED);
    cv::Mat warped;
    cv::warpPerspective(img, warped, M, img.size());
    std::vector<cv::Point2f> center = {{50, 50}}, centerMapped;
    cv::perspectiveTransform(center, centerMapped, M);
    XCTAssertEqual((int)warped.at<uchar>((int)std::lround(centerMapped[0].y),
                                         (int)std::lround(centerMapped[0].x)),
                   255);
}

- (void)testFindHomographyRANSACWithOutliers {
    cv::setRNGSeed(12345);

    // Ground-truth homography: mild perspective + translation.
    cv::Matx33d Htrue(1.02, 0.03, 5.0,
                      -0.02, 0.98, -3.0,
                      1e-4, -5e-5, 1.0);

    std::vector<cv::Point2f> src, dst;
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            cv::Point2f p(x * 25.0f, y * 25.0f);
            cv::Vec3d q = Htrue * cv::Vec3d(p.x, p.y, 1.0);
            src.push_back(p);
            dst.push_back(cv::Point2f((float)(q[0] / q[2]), (float)(q[1] / q[2])));
        }
    }
    // Poison ~15% of the correspondences.
    for (size_t i = 0; i < src.size(); i += 7) {
        dst[i] += cv::Point2f(60.0f + (float)i, -45.0f);
    }

    cv::Mat mask;
    cv::Mat H = cv::findHomography(src, dst, cv::RANSAC, 2.0, mask);
    XCTAssertFalse(H.empty());
    XCTAssertEqual(H.type(), CV_64FC1);

    // The recovered H must map clean points onto their true images.
    std::vector<cv::Point2f> mapped;
    cv::perspectiveTransform(src, mapped, H);
    int checked = 0;
    for (size_t i = 0; i < src.size(); i++) {
        if (i % 7 == 0) continue;  // skip poisoned pairs
        XCTAssertEqualWithAccuracy(mapped[i].x, dst[i].x, 0.5);
        XCTAssertEqualWithAccuracy(mapped[i].y, dst[i].y, 0.5);
        checked++;
    }
    XCTAssertGreaterThan(checked, 40);

    // The inlier mask must reject most poisoned pairs and keep most clean ones.
    int inliers = cv::countNonZero(mask);
    XCTAssertGreaterThan(inliers, 40);
    XCTAssertLessThanOrEqual(inliers, (int)src.size() - 8);

    // LMEDS path.
    cv::Mat maskL;
    cv::Mat HL = cv::findHomography(src, dst, cv::LMEDS, 2.0, maskL);
    XCTAssertFalse(HL.empty());

    // Method 0 (least squares) on the clean subset.
    std::vector<cv::Point2f> srcClean, dstClean;
    for (size_t i = 0; i < src.size(); i++) {
        if (i % 7 == 0) continue;
        srcClean.push_back(src[i]);
        dstClean.push_back(dst[i]);
    }
    cv::Mat H0 = cv::findHomography(srcClean, dstClean, 0);
    XCTAssertFalse(H0.empty());
    XCTAssertEqualWithAccuracy(H0.at<double>(0, 2), 5.0, 0.05);
}

- (void)testEstimateAffine2DLMEDS {
    cv::setRNGSeed(999);
    std::vector<cv::Point2f> src, dst;
    for (int i = 0; i < 30; i++) {
        cv::Point2f p((float)(i % 6) * 10.0f, (float)(i / 6) * 10.0f);
        src.push_back(p);
        dst.push_back(cv::Point2f(0.9f * p.x - 0.1f * p.y + 4.0f,
                                  0.1f * p.x + 0.9f * p.y - 2.0f));
    }
    dst[5] += cv::Point2f(50.0f, 50.0f);  // one outlier

    cv::Mat inliers;
    cv::Mat A = cv::estimateAffine2D(src, dst, inliers, cv::LMEDS);
    XCTAssertFalse(A.empty());
    XCTAssertEqual(A.rows, 2);
    XCTAssertEqual(A.cols, 3);
    XCTAssertEqualWithAccuracy(A.at<double>(0, 0), 0.9, 1e-3);
    XCTAssertEqualWithAccuracy(A.at<double>(1, 2), -2.0, 1e-3);
    XCTAssertEqual((int)inliers.at<uchar>(5, 0), 0);  // outlier rejected
}

- (void)testPipelinePrimitives {
    // The remaining imgproc facilities the port relies on, in one pass.
    cv::Mat img = cv::Mat::zeros(64, 64, CV_8UC1);
    cv::rectangle(img, cv::Rect(16, 16, 32, 32), cv::Scalar(255), cv::FILLED);

    cv::Mat blurred;
    cv::GaussianBlur(img, blurred, cv::Size(5, 5), 1.0);
    XCTAssertEqual((int)blurred.at<uchar>(32, 32), 255);

    cv::Mat small;
    cv::resize(img, small, cv::Size(32, 32), 0, 0, cv::INTER_AREA);
    XCTAssertEqual(small.rows, 32);
    XCTAssertEqual((int)small.at<uchar>(16, 16), 255);

    cv::Mat edges;
    cv::Canny(blurred, edges, 50, 150);
    XCTAssertGreaterThan(cv::countNonZero(edges), 0);

    std::vector<cv::Vec4i> lines;
    cv::HoughLinesP(edges, lines, 1, CV_PI / 180, 20, 20, 4);
    XCTAssertGreaterThan((int)lines.size(), 0);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(img, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    XCTAssertEqual((int)contours.size(), 1);
    double area = cv::contourArea(contours[0]);
    XCTAssertEqualWithAccuracy(area, 31.0 * 31.0, 1.0);

    std::vector<cv::Point> hull;
    cv::convexHull(contours[0], hull);
    XCTAssertGreaterThanOrEqual((int)hull.size(), 4);

    std::vector<cv::Point> approx;
    cv::approxPolyDP(contours[0], approx, 0.02 * cv::arcLength(contours[0], true), true);
    XCTAssertEqual((int)approx.size(), 4);

    cv::Mat dist;
    cv::distanceTransform(img, dist, cv::DIST_L2, 5);
    double minV, maxV;
    cv::minMaxLoc(dist, &minV, &maxV);
    XCTAssertEqualWithAccuracy(maxV, 16.0, 1.5);

    // SVD sanity: singular values of a diagonal matrix.
    cv::Mat Adiag = (cv::Mat_<double>(2, 2) << 3.0, 0.0, 0.0, 2.0);
    cv::Mat w, u, vt;
    cv::SVDecomp(Adiag, w, u, vt);
    XCTAssertEqualWithAccuracy(w.at<double>(0), 3.0, 1e-9);
    XCTAssertEqualWithAccuracy(w.at<double>(1), 2.0, 1e-9);

    // cv::Exception really is thrown and catchable (used as control flow).
    bool caught = false;
    try {
        cv::Mat bad;
        cv::cvtColor(bad, bad, cv::COLOR_BGR2GRAY);
    } catch (const cv::Exception &) {
        caught = true;
    }
    XCTAssertTrue(caught);
}

@end
