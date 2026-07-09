//
//  gr_testbridge.cpp
//  CGobanRecog
//
//  Implementation of the test/diagnostic seam. Thin wrappers over the internal
//  gobanrecog:: helpers; builds the cv:: inputs from the plain-std arguments so
//  the Swift native tests never touch OpenCV.
//

#include "GobanRecogTestBridge.hpp"

#include <stdexcept>
#include <string>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/core/utils/logger.hpp>

#include "gr_constants.h"
#include "gr_errors.h"
#include "gr_parity.h"
#include "gr_types.h"

namespace gobanrecog {
namespace testbridge {

namespace {

std::vector<std::string> splitRows(const char* rowsNL) {
    std::vector<std::string> rows;
    std::string cur;
    for (const char* p = rowsNL; *p != '\0'; ++p) {
        if (*p == '\n') {
            rows.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(*p);
        }
    }
    rows.push_back(cur);  // final (or only) row; trailing '\n' would add empty
    return rows;
}

std::string joinRows(const std::vector<std::string>& rows) {
    std::string out;
    for (size_t i = 0; i < rows.size(); ++i) {
        if (i) out.push_back('\n');
        out += rows[i];
    }
    return out;
}

}  // namespace

double np_round(double x) {
    return gobanrecog::np_round(x);
}

double np_percentile(const double* v, int n, double q) {
    return gobanrecog::np_percentile(std::vector<double>(v, v + n), q);
}

int np_percentile_range_throws(const double* v, int n, double q) {
    try {
        gobanrecog::np_percentile(std::vector<double>(v, v + n), q);
        return 0;
    } catch (const std::invalid_argument&) {
        return 1;
    }
}

double np_median(const double* v, int n) {
    return gobanrecog::np_median(std::vector<double>(v, v + n));
}

double np_median_f32(const float* v, int n) {
    cv::Mat m(1, n, CV_32F);
    for (int i = 0; i < n; ++i) m.at<float>(0, i) = v[i];
    return gobanrecog::np_median(m);
}

double np_median_u8(const unsigned char* v, int n) {
    cv::Mat m(1, n, CV_8U);
    for (int i = 0; i < n; ++i) m.at<unsigned char>(0, i) = v[i];
    return gobanrecog::np_median(m);
}

void np_median_axis0(const double* data, int rows, int cols, double* out) {
    cv::Mat m(rows, cols, CV_64F);
    for (int r = 0; r < rows; ++r) {
        for (int c = 0; c < cols; ++c) {
            m.at<double>(r, c) = data[r * cols + c];
        }
    }
    cv::Mat med = gobanrecog::np_median_axis0(m);
    for (int c = 0; c < cols; ++c) out[c] = med.at<double>(0, c);
}

void lstsq(const double* A, int m, int n, const double* B, int bcols, double* out) {
    cv::Mat Am(m, n, CV_64F);
    for (int i = 0; i < m * n; ++i) Am.at<double>(i / n, i % n) = A[i];
    cv::Mat Bm(m, bcols, CV_64F);
    for (int i = 0; i < m * bcols; ++i) Bm.at<double>(i / bcols, i % bcols) = B[i];
    cv::Mat x = gobanrecog::lstsq(Am, Bm);  // n x bcols
    for (int i = 0; i < n * bcols; ++i) out[i] = x.at<double>(i / bcols, i % bcols);
}

void pinv(const double* A, int n, double* out) {
    cv::Mat Am(n, n, CV_64F);
    for (int i = 0; i < n * n; ++i) Am.at<double>(i / n, i % n) = A[i];
    cv::Mat p = gobanrecog::pinv(Am);
    for (int i = 0; i < n * n; ++i) out[i] = p.at<double>(i / n, i % n);
}

int matrix_rank(const double* A, int m, int n) {
    cv::Mat Am(m, n, CV_64F);
    for (int i = 0; i < m * n; ++i) Am.at<double>(i / n, i % n) = A[i];
    return gobanrecog::matrix_rank(Am);
}

int inv3x3(const double* H, double* out9) {
    cv::Mat Hm(3, 3, CV_64F);
    for (int i = 0; i < 9; ++i) Hm.at<double>(i / 3, i % 3) = H[i];
    try {
        cv::Mat inv = gobanrecog::inv3x3(Hm);
        for (int i = 0; i < 9; ++i) out9[i] = inv.at<double>(i / 3, i % 3);
        return 0;
    } catch (const LinAlgError&) {
        return 1;
    }
}

int solve2x2(const double* A4, const double* b2, double* out2) {
    cv::Mat Am(2, 2, CV_64F);
    for (int i = 0; i < 4; ++i) Am.at<double>(i / 2, i % 2) = A4[i];
    cv::Vec2d b(b2[0], b2[1]);
    try {
        cv::Vec2d x = gobanrecog::solve2x2(Am, b);
        out2[0] = x[0];
        out2[1] = x[1];
        return 0;
    } catch (const LinAlgError&) {
        return 1;
    }
}

double np_mean_f32(const float* v, int n) {
    return static_cast<double>(gobanrecog::np_mean(v, static_cast<size_t>(n)));
}

double np_mean_f64(const double* v, int n) {
    return gobanrecog::np_mean(v, static_cast<size_t>(n));
}

double np_percentile_f32(const float* v, int n, double q) {
    return static_cast<double>(
        gobanrecog::np_percentile(std::vector<float>(v, v + n), q));
}

int np_arange(double start, double stop, double step, double* out, int cap) {
    const std::vector<double> a = gobanrecog::np_arange(start, stop, step);
    const int n = static_cast<int>(a.size());
    for (int i = 0; i < n && i < cap; ++i) out[i] = a[static_cast<size_t>(i)];
    return n;
}

// The grid_* wrappers declared alongside these are DEFINED in gr_grid.cpp so
// they can reach that file's local statics (see the note there).

void quiet_opencv_logs() {
    cv::utils::logging::setLogLevel(cv::utils::logging::LOG_LEVEL_SILENT);
}

int stone_kernel(double* out289) {
    const cv::Mat& k = gobanrecog::stoneKernel();
    int nonzero = 0;
    for (int i = 0; i < 289; ++i) {
        const float val = k.at<float>(i / 17, i % 17);
        out289[i] = static_cast<double>(val);
        if (val != 0.0f) ++nonzero;
    }
    return nonzero;
}

void node_offsets(double* out50) {
    const std::vector<std::pair<double, double>>& offs = gobanrecog::nodeOffsets();
    for (size_t i = 0; i < offs.size(); ++i) {
        out50[2 * i] = offs[i].first;
        out50[2 * i + 1] = offs[i].second;
    }
}

std::string board_validate(int size, const char* rowsNL) {
    try {
        BoardState bs(size, splitRows(rowsNL));
        (void)bs;
        return "";
    } catch (const std::invalid_argument& e) {
        return std::string(e.what());
    }
}

std::string board_points(int size, const char* rowsNL, int colorCode) {
    try {
        BoardState bs(size, splitRows(rowsNL));
        std::string out;
        for (const auto& p : bs.points(static_cast<char>(colorCode))) {
            if (!out.empty()) out.push_back(';');
            out += std::to_string(p.first) + "," + std::to_string(p.second);
        }
        return out;
    } catch (const std::invalid_argument&) {
        return "!";
    }
}

int board_stone_at(int size, const char* rowsNL, int col, int row) {
    try {
        BoardState bs(size, splitRows(rowsNL));
        return static_cast<int>(bs.stoneAt(col, row));
    } catch (const std::invalid_argument&) {
        return -1;
    }
}

std::string board_empty(int size) {
    try {
        return joinRows(BoardState::empty(size).rows);
    } catch (const std::invalid_argument&) {
        return "!";
    }
}

std::string board_from_grid(const char* rowsNL) {
    try {
        std::vector<std::string> rows = splitRows(rowsNL);
        std::vector<std::vector<char>> grid;
        grid.reserve(rows.size());
        for (const auto& r : rows) grid.emplace_back(r.begin(), r.end());
        BoardState bs = BoardState::fromGrid(grid);
        return std::to_string(bs.size) + "|" + joinRows(bs.rows);
    } catch (const std::invalid_argument&) {
        return "!";
    }
}

}  // namespace testbridge
}  // namespace gobanrecog
