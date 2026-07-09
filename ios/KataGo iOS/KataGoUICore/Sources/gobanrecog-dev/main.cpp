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
//    Prints one JSON object to stdout (see grid_stage_json in
//    GobanRecogTestBridge.hpp for the schema). Python-flavored JSON:
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
                 "  <type>: u8 (row-major grayscale uint8)\n");
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

}  // namespace

int main(int argc, char** argv) {
    // OpenCV's first use logs an INFO banner to stdout, corrupting the JSON.
    // The OPENCV_LOG_LEVEL env var is cached before main runs, so silence the
    // logger through the bridge (this file stays cv-free).
    gobanrecog::testbridge::quiet_opencv_logs();
    if (argc < 2) return usage();
    if (std::strcmp(argv[1], "grid") == 0) return runGrid(argc, argv);
    return usage();
}
