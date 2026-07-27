//
//  main.cpp
//  gobanrecog-cli
//
//  Command-line recognizer for the CGobanRecog port — the macOS tool the
//  Task-10 600-image eval drives. NOT part of any SwiftPM product/app scheme
//  (like gobanrecog-dev); run on macOS via `swift run gobanrecog-cli` or the
//  built binary in .build/. Depends ONLY on CGobanRecog and reaches the pipeline
//  through the cv-free GobanRecogTestBridge seam (imgcodecs is NOT vendored, so
//  this file never touches cv:: and never decodes an image itself).
//
//  Input contract (imgcodecs-free)
//  -------------------------------
//  The tool takes a RAW BGR dump, NOT an encoded image, because OpenCV's
//  imgcodecs module is not vendored. The dump is exactly what cv2.imread(path)
//  produces and writes with numpy's `.tofile()`:
//    * shape (height, width, 3), dtype uint8, BGR channel order
//    * C-contiguous, row-major, TIGHTLY packed (byte offset of pixel (y,x)
//      channel c = ((y*width + x)*3 + c); stride = width*3, no padding)
//  This is byte-for-byte identical to what recognize_image(cv2.imread(path))
//  sees in Python. The Python eval adapter (GobanRecog tools/cli_sanity.py)
//  produces it with `cv2.imread(path).tofile(raw)` and passes width/height (a
//  raw dump carries no header). See task-9-report.md.
//
//  Usage
//  -----
//    gobanrecog-cli <bgr.raw> <width> <height> [-o out.sgf] [--debug-json]
//
//    Normal mode: on "ok" write board_to_sgf (to -o, else stdout) and print
//    "detected NxN, confidence C.CC" to stderr (exit 0); on abstention print
//    "error: failed:<reason>" to stderr and exit 2 (matches cli.py semantics).
//    --debug-json: print the full recognize debug JSON to stdout; exit code
//    still reflects the outcome (0 ok, 2 abstain) so eval can branch on it.
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
                 "usage: gobanrecog-cli <bgr.raw> <width> <height> [-o out.sgf] [--debug-json]\n"
                 "                       [--quad x0,y0,x1,y1,x2,y2,x3,y3] [--size N]\n"
                 "  <bgr.raw>: row-major uint8 BGR HxWx3 (cv2.imread(path).tofile(raw))\n"
                 "  -o <path>: write the SGF to <path> instead of stdout\n"
                 "  --debug-json: dump the full recognize debug JSON to stdout\n"
                 "  --quad: the board's four OUTER GRID-LINE INTERSECTIONS in image\n"
                 "          pixels, TL,TR,BR,BL — the app's manual-grid path. Skips the\n"
                 "          quad proposers and lifts the confidence floor, so check the\n"
                 "          reported confidence rather than trusting \"ok\".\n"
                 "  --size: board size to force (9/13/19); only with --quad\n");
    return 2;
}

std::vector<unsigned char> readFile(const char* path) {
    std::FILE* f = std::fopen(path, "rb");
    if (f == nullptr) {
        std::fprintf(stderr, "gobanrecog-cli: cannot open %s\n", path);
        std::exit(1);
    }
    std::fseek(f, 0, SEEK_END);
    const long size = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> data(static_cast<size_t>(size));
    const size_t got = std::fread(data.data(), 1, data.size(), f);
    std::fclose(f);
    if (got != data.size()) {
        std::fprintf(stderr, "gobanrecog-cli: short read on %s\n", path);
        std::exit(1);
    }
    return data;
}

// Parses "x0,y0,x1,y1,x2,y2,x3,y3" into eight doubles. Returns false unless
// exactly eight numbers were present.
bool parseQuad(const char* text, double* out8) {
    int count = 0;
    const char* cursor = text;
    while (count < 8) {
        char* end = nullptr;
        const double value = std::strtod(cursor, &end);
        if (end == cursor) return false;
        out8[count++] = value;
        cursor = end;
        if (*cursor == ',') ++cursor;
        else break;
    }
    return count == 8 && *cursor == '\0';
}

}  // namespace

int main(int argc, char** argv) {
    // OpenCV's first use logs an INFO banner to stdout, which would corrupt the
    // SGF / JSON payload. The OPENCV_LOG_LEVEL env var is cached before main
    // runs, so silence the logger through the bridge (this file stays cv-free),
    // exactly as gobanrecog-dev does.
    gobanrecog::testbridge::quiet_opencv_logs();

    if (argc < 4) return usage();

    const char* rawPath = argv[1];
    const int width = std::atoi(argv[2]);
    const int height = std::atoi(argv[3]);
    const char* outPath = nullptr;
    bool debugJson = false;
    double quad[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    bool haveQuad = false;
    int forcedSize = 0;

    for (int i = 4; i < argc; ++i) {
        if (std::strcmp(argv[i], "-o") == 0 || std::strcmp(argv[i], "--output") == 0) {
            if (i + 1 >= argc) return usage();
            outPath = argv[i + 1];
            ++i;
        } else if (std::strcmp(argv[i], "--debug-json") == 0) {
            debugJson = true;
        } else if (std::strcmp(argv[i], "--quad") == 0) {
            if (i + 1 >= argc) return usage();
            if (!parseQuad(argv[i + 1], quad)) {
                std::fprintf(stderr, "gobanrecog-cli: --quad needs 8 comma-separated numbers\n");
                return 2;
            }
            haveQuad = true;
            ++i;
        } else if (std::strcmp(argv[i], "--size") == 0) {
            if (i + 1 >= argc) return usage();
            forcedSize = std::atoi(argv[i + 1]);
            ++i;
        } else {
            return usage();
        }
    }

    if (width <= 0 || height <= 0) return usage();
    if (forcedSize != 0 && !haveQuad) {
        std::fprintf(stderr, "gobanrecog-cli: --size requires --quad\n");
        return 2;
    }
    if (debugJson && haveQuad) {
        // The debug JSON seam has no quad variant; the status line does.
        std::fprintf(stderr, "gobanrecog-cli: --debug-json and --quad are exclusive\n");
        return 2;
    }

    const std::vector<unsigned char> img = readFile(rawPath);
    if (static_cast<long long>(img.size()) != 3LL * width * height) {
        std::fprintf(stderr, "gobanrecog-cli: %s has %zu bytes, expected %d*%d*3=%d\n",
                     rawPath, img.size(), width, height, width * height * 3);
        return 1;
    }

    if (debugJson) {
        const std::string json =
            gobanrecog::testbridge::recognize_debug_json(img.data(), width, height);
        std::fwrite(json.data(), 1, json.size(), stdout);
        std::fputc('\n', stdout);
        // Exit code mirrors recognition outcome so eval can branch uniformly.
        const bool ok = json.find("\"status\": \"ok\"") != std::string::npos;
        return ok ? 0 : 2;
    }

    // Normal mode: TAB line "<status>\t<size>\t<conf>\t<quad_source>\t<sgf>".
    const std::string line =
        haveQuad
            ? gobanrecog::testbridge::recognize_status_line_with_quad(img.data(), width, height,
                                                                      quad, forcedSize)
            : gobanrecog::testbridge::recognize_status_line(img.data(), width, height);

    // Split on the first four tabs; the fifth field (sgf) may be empty and
    // never contains a tab.
    std::string fields[5];
    size_t start = 0;
    int fi = 0;
    for (; fi < 4; ++fi) {
        const size_t tab = line.find('\t', start);
        if (tab == std::string::npos) {  // malformed — should never happen
            std::fprintf(stderr, "gobanrecog-cli: internal: malformed status line\n");
            return 1;
        }
        fields[fi] = line.substr(start, tab - start);
        start = tab + 1;
    }
    fields[4] = line.substr(start);

    const std::string& status = fields[0];
    const int boardSize = std::atoi(fields[1].c_str());
    const double confidence = std::atof(fields[2].c_str());
    const std::string& sgf = fields[4];

    if (status != "ok") {
        // cli.py: print(f"error: {result.status}", file=sys.stderr); return 2
        std::fprintf(stderr, "error: %s\n", status.c_str());
        return 2;
    }

    if (outPath != nullptr) {
        std::FILE* f = std::fopen(outPath, "wb");
        if (f == nullptr) {
            std::fprintf(stderr, "gobanrecog-cli: cannot write %s\n", outPath);
            return 1;
        }
        std::fwrite(sgf.data(), 1, sgf.size(), f);
        std::fputc('\n', f);  // run.py writes board_to_sgf(...) + "\n"
        std::fclose(f);
    } else {
        std::fwrite(sgf.data(), 1, sgf.size(), stdout);
        std::fputc('\n', stdout);
    }

    // cli.py: f"detected {n}x{n}, confidence {conf:.2f}" to stderr.
    std::fprintf(stderr, "detected %dx%d, confidence %.2f\n", boardSize, boardSize, confidence);
    return 0;
}
