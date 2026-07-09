//
//  main.cpp
//  gobanrecog-dev
//
//  Micro-parity harness CLI for the CGobanRecog port (Task 4; later port tasks
//  add subcommands). NOT part of any SwiftPM product — app schemes never build
//  it; it exists for `swift run gobanrecog-dev` on macOS, paired with the
//  GobanRecog repo's tools/dump_stage.py + tools/compare_stage.py.
//
//  Usage:
//    gobanrecog-dev grid <in.raw> <width> <height> <type>
//                   [--quad x0 y0 x1 y1 x2 y2 x3 y3] [--dump-rect <path>]
//
//    <in.raw>  row-major raw dump; <type> must be "u8" (grayscale uint8).
//    Without --quad, in.raw IS the rectified frame (side = SPAN + 2*PAD =
//    1100) and only choose_size runs. With --quad (TL,TR,BR,BL corner pairs
//    in image pixels), in.raw is the full grayscale image; rectify_quad runs
//    first (the JSON gains an "H" key) and --dump-rect optionally writes the
//    rectified frame's raw bytes for byte-level comparison against Python's.
//
//    gobanrecog-dev stones <bgr.raw> <width> <height> h0 h1 h2 h3 h4 h5 h6 h7 h8
//                   <board_size> [--dump-rect <path>]
//    gobanrecog-dev stones --pre-rectified <rect.raw> <side> <board_size>
//
//    <bgr.raw>  row-major uint8 BGR HxWx3 image; h0..h8 = row-major H_grid.
//    classify_stones runs fully (_rectify_lattice first; the JSON gains an
//    "M" key) and --dump-rect optionally writes the rectified BGR frame's raw
//    bytes. With --pre-rectified, <rect.raw> IS the canonical rectified BGR
//    frame (side = 2*PAD + (n-1)*SP) and the warp is skipped — the same-bytes
//    micro-parity leg (compare with compare_stage.py --exact).
//
//    Prints one JSON object to stdout (see grid_stage_json / stones_stage_json
//    in GobanRecogTestBridge.hpp for the schemas). Python-flavored JSON:
//    NaN/Infinity tokens are permitted (json.loads accepts them).
//

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <GobanRecogTestBridge.hpp>

namespace {

int usage() {
    std::fprintf(stderr,
                 "usage: gobanrecog-dev grid <in.raw> <width> <height> <type>\n"
                 "                      [--quad x0 y0 x1 y1 x2 y2 x3 y3] [--dump-rect <path>]\n"
                 "  <type>: u8 (row-major grayscale uint8)\n"
                 "       gobanrecog-dev stones <bgr.raw> <width> <height> h0 h1 h2 h3 h4 h5 h6 h7 h8\n"
                 "                      <board_size> [--dump-rect <path>]\n"
                 "       gobanrecog-dev stones --pre-rectified <rect.raw> <side> <board_size>\n"
                 "  <bgr.raw>/<rect.raw>: row-major uint8 BGR HxWx3\n"
                 "       gobanrecog-dev slat <gray.raw> <width> <height> <n_seed>\n"
                 "                      --seed h0 h1 h2 h3 h4 h5 h6 h7 h8 [--margin M]\n"
                 "       gobanrecog-dev slat --pre-mapped <avg.f64.raw> <stoneness.f64.raw>\n"
                 "                      <side> <scale> --W w0 w1 w2 w3 w4 w5 w6 w7 w8\n"
                 "  <gray.raw>: row-major uint8 HxW; avg/stoneness: row-major float64 side x side\n"
                 "       gobanrecog-dev proposers <bgr.raw> <width> <height>\n"
                 "  <bgr.raw>: row-major uint8 BGR HxWx3 (runs all five quad proposers)\n"
                 "       gobanrecog-dev detect <bgr.raw> <width> <height>\n"
                 "  <bgr.raw>: row-major uint8 BGR HxWx3 (runs full detect_board)\n");
    return 2;
}

std::vector<unsigned char> readFile(const char* path) {
    std::FILE* f = std::fopen(path, "rb");
    if (f == nullptr) {
        std::fprintf(stderr, "gobanrecog-dev: cannot open %s\n", path);
        std::exit(1);
    }
    std::fseek(f, 0, SEEK_END);
    const long size = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> data(static_cast<size_t>(size));
    const size_t got = std::fread(data.data(), 1, data.size(), f);
    std::fclose(f);
    if (got != data.size()) {
        std::fprintf(stderr, "gobanrecog-dev: short read on %s\n", path);
        std::exit(1);
    }
    return data;
}

int runGrid(int argc, char** argv) {
    if (argc < 6) return usage();
    const char* inPath = argv[2];
    const int width = std::atoi(argv[3]);
    const int height = std::atoi(argv[4]);
    const char* type = argv[5];
    if (std::strcmp(type, "u8") != 0) {
        std::fprintf(stderr, "gobanrecog-dev: unsupported type '%s' (only u8)\n", type);
        return 2;
    }
    bool haveQuad = false;
    double quad[8] = {0};
    const char* dumpRectPath = nullptr;
    for (int i = 6; i < argc; ++i) {
        if (std::strcmp(argv[i], "--quad") == 0) {
            if (i + 8 >= argc) return usage();
            for (int k = 0; k < 8; ++k) quad[k] = std::atof(argv[i + 1 + k]);
            haveQuad = true;
            i += 8;
        } else if (std::strcmp(argv[i], "--dump-rect") == 0) {
            if (i + 1 >= argc) return usage();
            dumpRectPath = argv[i + 1];
            i += 1;
        } else {
            return usage();
        }
    }
    const std::vector<unsigned char> img = readFile(inPath);
    if (static_cast<long long>(img.size()) != 1LL * width * height) {
        std::fprintf(stderr, "gobanrecog-dev: %s has %zu bytes, expected %d*%d=%d\n",
                     inPath, img.size(), width, height, width * height);
        return 1;
    }
    if (dumpRectPath != nullptr) {
        if (!haveQuad) {
            std::fprintf(stderr, "gobanrecog-dev: --dump-rect requires --quad\n");
            return 2;
        }
        // SPAN + 2*RECT_PAD = 1100 (grid.py rectified frame)
        std::vector<unsigned char> rect(1100u * 1100u);
        double h9[9];
        const int side = gobanrecog::testbridge::grid_rectify(
            img.data(), width, height, quad, rect.data(), h9);
        std::FILE* f = std::fopen(dumpRectPath, "wb");
        if (f == nullptr) {
            std::fprintf(stderr, "gobanrecog-dev: cannot write %s\n", dumpRectPath);
            return 1;
        }
        std::fwrite(rect.data(), 1, static_cast<size_t>(side) * side, f);
        std::fclose(f);
    }
    const std::string json = gobanrecog::testbridge::grid_stage_json(
        img.data(), width, height, haveQuad ? quad : nullptr);
    std::fwrite(json.data(), 1, json.size(), stdout);
    std::fputc('\n', stdout);
    return 0;
}

int runStones(int argc, char** argv) {
    // Pre-rectified (same-bytes leg): stones --pre-rectified <rect.raw> <side> <n>
    if (argc >= 3 && std::strcmp(argv[2], "--pre-rectified") == 0) {
        if (argc != 6) return usage();
        const char* inPath = argv[3];
        const int side = std::atoi(argv[4]);
        const int boardSize = std::atoi(argv[5]);
        const std::vector<unsigned char> img = readFile(inPath);
        if (static_cast<long long>(img.size()) != 3LL * side * side) {
            std::fprintf(stderr, "gobanrecog-dev: %s has %zu bytes, expected %d*%d*3=%d\n",
                         inPath, img.size(), side, side, side * side * 3);
            return 1;
        }
        const std::string json = gobanrecog::testbridge::stones_stage_json(
            img.data(), side, side, nullptr, boardSize);
        std::fwrite(json.data(), 1, json.size(), stdout);
        std::fputc('\n', stdout);
        return 0;
    }
    // Full: stones <bgr.raw> <width> <height> h0..h8 <board_size> [--dump-rect <path>]
    if (argc < 15) return usage();
    const char* inPath = argv[2];
    const int width = std::atoi(argv[3]);
    const int height = std::atoi(argv[4]);
    double h9[9];
    for (int k = 0; k < 9; ++k) h9[k] = std::atof(argv[5 + k]);
    const int boardSize = std::atoi(argv[14]);
    const char* dumpRectPath = nullptr;
    for (int i = 15; i < argc; ++i) {
        if (std::strcmp(argv[i], "--dump-rect") == 0) {
            if (i + 1 >= argc) return usage();
            dumpRectPath = argv[i + 1];
            i += 1;
        } else {
            return usage();
        }
    }
    const std::vector<unsigned char> img = readFile(inPath);
    if (static_cast<long long>(img.size()) != 3LL * width * height) {
        std::fprintf(stderr, "gobanrecog-dev: %s has %zu bytes, expected %d*%d*3=%d\n",
                     inPath, img.size(), width, height, width * height * 3);
        return 1;
    }
    if (dumpRectPath != nullptr) {
        // side = 2*PAD + (n-1)*SP (stones.py canonical frame)
        const int side = 2 * 48 + (boardSize - 1) * 32;
        std::vector<unsigned char> rect(static_cast<size_t>(side) * side * 3);
        double m9[9];
        gobanrecog::testbridge::stones_rectify(img.data(), width, height, h9,
                                               boardSize, rect.data(), m9);
        std::FILE* f = std::fopen(dumpRectPath, "wb");
        if (f == nullptr) {
            std::fprintf(stderr, "gobanrecog-dev: cannot write %s\n", dumpRectPath);
            return 1;
        }
        std::fwrite(rect.data(), 1, rect.size(), f);
        std::fclose(f);
    }
    const std::string json = gobanrecog::testbridge::stones_stage_json(
        img.data(), width, height, h9, boardSize);
    std::fwrite(json.data(), 1, json.size(), stdout);
    std::fputc('\n', stdout);
    return 0;
}

std::vector<double> readDoubleFile(const char* path) {
    const std::vector<unsigned char> bytes = readFile(path);
    if (bytes.size() % sizeof(double) != 0) {
        std::fprintf(stderr, "gobanrecog-dev: %s size %zu not a multiple of 8\n", path,
                     bytes.size());
        std::exit(1);
    }
    std::vector<double> out(bytes.size() / sizeof(double));
    std::memcpy(out.data(), bytes.data(), bytes.size());
    return out;
}

int runSlat(int argc, char** argv) {
    // Pre-peaks (bit-exact gate): slat --pre-peaks <peaks.f64.raw> <npeaks> --W w0..w8
    if (argc >= 3 && std::strcmp(argv[2], "--pre-peaks") == 0) {
        if (argc < 5) return usage();
        const char* peaksPath = argv[3];
        const int nPeaks = std::atoi(argv[4]);
        double w9[9] = {0};
        bool haveW = false;
        for (int i = 5; i < argc; ++i) {
            if (std::strcmp(argv[i], "--W") == 0) {
                if (i + 9 >= argc) return usage();
                for (int k = 0; k < 9; ++k) w9[k] = std::atof(argv[i + 1 + k]);
                haveW = true;
                i += 9;
            } else {
                return usage();
            }
        }
        if (!haveW) return usage();
        const std::vector<double> peaks = readDoubleFile(peaksPath);
        if (static_cast<long long>(peaks.size()) != 2LL * nPeaks) {
            std::fprintf(stderr, "gobanrecog-dev: peaks must be %d*2 doubles\n", nPeaks);
            return 1;
        }
        const std::string json =
            gobanrecog::testbridge::slat_stage_json_prepeaks(peaks.data(), nPeaks, w9);
        std::fwrite(json.data(), 1, json.size(), stdout);
        std::fputc('\n', stdout);
        return 0;
    }
    // LMEDS debug: slat --lmeds <src.f64.raw> <dst.f64.raw> <n>
    if (argc >= 3 && std::strcmp(argv[2], "--lmeds") == 0) {
        if (argc != 6) return usage();
        const int n = std::atoi(argv[5]);
        const std::vector<double> src = readDoubleFile(argv[3]);
        const std::vector<double> dst = readDoubleFile(argv[4]);
        if (static_cast<long long>(src.size()) != 2LL * n ||
            static_cast<long long>(dst.size()) != 2LL * n)
            return 1;
        double T9[9] = {0};
        const int ok = gobanrecog::testbridge::slat_find_homography_lmeds(src.data(), dst.data(), n, T9);
        std::string out = "{\"ok\": " + std::to_string(ok) + ", \"T\": [";
        for (int i = 0; i < 9; ++i) {
            if (i) out += ", ";
            char b[40];
            std::snprintf(b, sizeof(b), "%.17g", T9[i]);
            out += b;
        }
        out += "]}";
        std::fwrite(out.data(), 1, out.size(), stdout);
        std::fputc('\n', stdout);
        return 0;
    }
    // Grow debug: slat --grow <peaks.f64.raw> <npeaks> <which(0|1)>
    if (argc >= 3 && std::strcmp(argv[2], "--grow") == 0) {
        if (argc != 6) return usage();
        const int nPeaks = std::atoi(argv[4]);
        const int which = std::atoi(argv[5]);
        const std::vector<double> peaks = readDoubleFile(argv[3]);
        if (static_cast<long long>(peaks.size()) != 2LL * nPeaks) return 1;
        std::vector<int> tri(3 * (nPeaks + 1));
        const int n = gobanrecog::testbridge::slat_grow_debug(peaks.data(), nPeaks, which,
                                                              tri.data(), nPeaks + 1);
        std::string out = "{\"count\": " + std::to_string(n) + ", \"coords\": [";
        for (int i = 0; i < std::min(n, nPeaks + 1); ++i) {
            if (i) out += ", ";
            out += "[" + std::to_string(tri[3 * i]) + ", " + std::to_string(tri[3 * i + 1]) +
                   ", " + std::to_string(tri[3 * i + 2]) + "]";
        }
        out += "]}";
        std::fwrite(out.data(), 1, out.size(), stdout);
        std::fputc('\n', stdout);
        return 0;
    }
    // Detector attribution: slat --detectors <avg.f64.raw> <stoneness.f64.raw> <side> <scale>
    if (argc >= 3 && std::strcmp(argv[2], "--detectors") == 0) {
        if (argc != 7) return usage();
        const int side = std::atoi(argv[5]);
        const double scale = std::atof(argv[6]);
        const std::vector<double> avg = readDoubleFile(argv[3]);
        const std::vector<double> st = readDoubleFile(argv[4]);
        std::vector<double> ring(2 * 600), dt(2 * 600);
        // thr / min_sep replicate _union_peaks' _peaks_ring call.
        const double thr = std::max(0.45 * scale, 40.0);
        const int minSep = static_cast<int>(0.6 * 32);
        const int nr = gobanrecog::testbridge::slat_peaks_ring(avg.data(), side, thr, minSep,
                                                               ring.data(), 600);
        const int nd = gobanrecog::testbridge::slat_peaks_dt(st.data(), side, scale, dt.data(), 600);
        std::string out = "{\"ring\": [";
        for (int i = 0; i < std::min(nr, 600); ++i) {
            if (i) out += ", ";
            char b[64];
            std::snprintf(b, sizeof(b), "[%.17g, %.17g]", ring[2 * i], ring[2 * i + 1]);
            out += b;
        }
        out += "], \"dt\": [";
        for (int i = 0; i < std::min(nd, 600); ++i) {
            if (i) out += ", ";
            char b[64];
            std::snprintf(b, sizeof(b), "[%.17g, %.17g]", dt[2 * i], dt[2 * i + 1]);
            out += b;
        }
        out += "]}";
        std::fwrite(out.data(), 1, out.size(), stdout);
        std::fputc('\n', stdout);
        return 0;
    }
    // Pre-mapped (same-float64-map leg):
    //   slat --pre-mapped <avg.f64.raw> <stoneness.f64.raw> <side> <scale> --W w0..w8
    if (argc >= 3 && std::strcmp(argv[2], "--pre-mapped") == 0) {
        if (argc < 7) return usage();
        const char* avgPath = argv[3];
        const char* stPath = argv[4];
        const int side = std::atoi(argv[5]);
        const double scale = std::atof(argv[6]);
        double w9[9] = {0};
        bool haveW = false;
        for (int i = 7; i < argc; ++i) {
            if (std::strcmp(argv[i], "--W") == 0) {
                if (i + 9 >= argc) return usage();
                for (int k = 0; k < 9; ++k) w9[k] = std::atof(argv[i + 1 + k]);
                haveW = true;
                i += 9;
            } else {
                return usage();
            }
        }
        if (!haveW) return usage();
        const std::vector<double> avg = readDoubleFile(avgPath);
        const std::vector<double> st = readDoubleFile(stPath);
        const long long want = 1LL * side * side;
        if (static_cast<long long>(avg.size()) != want ||
            static_cast<long long>(st.size()) != want) {
            std::fprintf(stderr, "gobanrecog-dev: avg/stoneness must be %d*%d=%lld doubles\n",
                         side, side, want);
            return 1;
        }
        const std::string json = gobanrecog::testbridge::slat_stage_json_premapped(
            avg.data(), st.data(), side, scale, w9);
        std::fwrite(json.data(), 1, json.size(), stdout);
        std::fputc('\n', stdout);
        return 0;
    }
    // Full mode: slat <gray.raw> <width> <height> <n_seed> --seed h0..h8 [--margin M]
    if (argc < 5) return usage();
    const char* inPath = argv[2];
    const int width = std::atoi(argv[3]);
    const int height = std::atoi(argv[4]);
    const int nSeed = std::atoi(argv[5]);
    double seed9[9] = {0};
    bool haveSeed = false;
    int margin = 3;
    for (int i = 6; i < argc; ++i) {
        if (std::strcmp(argv[i], "--seed") == 0) {
            if (i + 9 >= argc) return usage();
            for (int k = 0; k < 9; ++k) seed9[k] = std::atof(argv[i + 1 + k]);
            haveSeed = true;
            i += 9;
        } else if (std::strcmp(argv[i], "--margin") == 0) {
            if (i + 1 >= argc) return usage();
            margin = std::atoi(argv[i + 1]);
            i += 1;
        } else {
            return usage();
        }
    }
    if (!haveSeed) return usage();
    const std::vector<unsigned char> img = readFile(inPath);
    if (static_cast<long long>(img.size()) != 1LL * width * height) {
        std::fprintf(stderr, "gobanrecog-dev: %s has %zu bytes, expected %d*%d=%d\n", inPath,
                     img.size(), width, height, width * height);
        return 1;
    }
    const std::string json = gobanrecog::testbridge::slat_stage_json(
        img.data(), width, height, seed9, nSeed, margin);
    std::fwrite(json.data(), 1, json.size(), stdout);
    std::fputc('\n', stdout);
    return 0;
}

int runProposers(int argc, char** argv) {
    // proposers <bgr.raw> <width> <height>
    if (argc != 5) return usage();
    const char* inPath = argv[2];
    const int width = std::atoi(argv[3]);
    const int height = std::atoi(argv[4]);
    const std::vector<unsigned char> img = readFile(inPath);
    if (static_cast<long long>(img.size()) != 3LL * width * height) {
        std::fprintf(stderr, "gobanrecog-dev: %s has %zu bytes, expected %d*%d*3=%d\n",
                     inPath, img.size(), width, height, width * height * 3);
        return 1;
    }
    const std::string json =
        gobanrecog::testbridge::proposers_stage_json(img.data(), width, height);
    std::fwrite(json.data(), 1, json.size(), stdout);
    std::fputc('\n', stdout);
    return 0;
}

int runDetect(int argc, char** argv) {
    // detect <bgr.raw> <width> <height>
    if (argc != 5) return usage();
    const char* inPath = argv[2];
    const int width = std::atoi(argv[3]);
    const int height = std::atoi(argv[4]);
    const std::vector<unsigned char> img = readFile(inPath);
    if (static_cast<long long>(img.size()) != 3LL * width * height) {
        std::fprintf(stderr, "gobanrecog-dev: %s has %zu bytes, expected %d*%d*3=%d\n",
                     inPath, img.size(), width, height, width * height * 3);
        return 1;
    }
    const std::string json =
        gobanrecog::testbridge::detect_stage_json(img.data(), width, height);
    std::fwrite(json.data(), 1, json.size(), stdout);
    std::fputc('\n', stdout);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    // OpenCV's first use logs an INFO banner to stdout, corrupting the JSON.
    // The OPENCV_LOG_LEVEL env var is cached before main runs, so silence the
    // logger through the bridge (this file stays cv-free).
    gobanrecog::testbridge::quiet_opencv_logs();
    if (argc < 2) return usage();
    if (std::strcmp(argv[1], "grid") == 0) return runGrid(argc, argv);
    if (std::strcmp(argv[1], "stones") == 0) return runStones(argc, argv);
    if (std::strcmp(argv[1], "slat") == 0) return runSlat(argc, argv);
    if (std::strcmp(argv[1], "proposers") == 0) return runProposers(argc, argv);
    if (std::strcmp(argv[1], "detect") == 0) return runDetect(argc, argv);
    return usage();
}
