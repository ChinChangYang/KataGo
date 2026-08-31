#!/usr/bin/env swift
//
//  frame_screenshots.swift
//  KataGo Anytime — README screenshot pipeline
//
//  Composites each raw device capture into Apple's product bezel and writes the
//  committed README image. Run with `swift frame_screenshots.swift` (no build
//  step, no package): Foundation + CoreGraphics + ImageIO only.
//
//    swift frame_screenshots.swift frame <rawDir> <bezelsDir> <outDir>
//    swift frame_screenshots.swift window <owner-name>
//
//  The `window` subcommand is here rather than in the shell script because
//  finding a window id needs `CGWindowListCopyWindowInfo`, and the same call
//  doubles as the Screen Recording pre-flight: window IDS and BOUNDS are
//  readable by anyone, but window NAMES of other processes are only returned to
//  a process that holds the permission. `screencapture -l<id>` without it
//  silently photographs the desktop picture instead of the window, so the shell
//  script has to know BEFORE it captures. No Accessibility permission is
//  involved anywhere.
//
//  WHY THE SCREEN RECT IS FLOOD-FILLED. A bezel PNG is transparent in two
//  places: outside the device outline AND inside the screen cut-out. A bounding
//  box over "all transparent pixels" is therefore the whole image and useless.
//  The screen is the connected transparent component that contains the image
//  centre, so a flood fill from the centre pixel is what isolates it — and it
//  gets the rounded corners, the Dynamic Island and the Watch's curved glass
//  for free, because those are opaque bezel pixels that the fill simply does
//  not enter.
//
//  Bezel files are NOT in the repository (Apple's Apple Design Resources
//  License forbids redistributing them); see bezels/README.md.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tunables (mirrored by verify_screenshots.py — keep them in step)

/// Committed width, device frame included. The 2D board draws a photographic
/// wood texture, so this is the widest that reliably stays under the size cap.
let defaultOutputWidth = 800
/// What a README image should weigh.
let targetBytes = 300 * 1024
/// What it may never weigh. `verify_screenshots.py` asserts the same number.
let maxBytes = 400 * 1024
/// Narrowest we will shrink to before giving up rather than ship a blurry hero.
let minOutputWidth = 300
/// Grow the screen mask by this many pixels before laying the capture under it,
/// so the bezel's own ANTIALIASED edge pixels — which are not alpha == 0 and so
/// are not in the fill — have something to blend against instead of showing a
/// one-pixel hairline of nothing.
let maskDilation = 2

// MARK: - Subjects

struct Subject {
    let name: String
    /// Case-insensitive globs matched against the bezel file NAME, best first.
    /// Empty means "no bezel": composite nothing, just resize.
    let bezelPatterns: [String]
}

/// The six README images. Apple ships no Vision Pro product bezel — and a
/// volumetric capture is a scene rather than a screen — so `vision-volume` is
/// committed unframed, deliberately.
let subjects: [Subject] = [
    Subject(name: "iphone-board", bezelPatterns: [
        "*iPhone*17*Black*Portrait*.png",
        "*iPhone*17*Portrait*.png",
        "*iPhone*17*.png",
    ]),
    // Portrait, to match the full-screen board the iPad shot shows.
    Subject(name: "ipad-board", bezelPatterns: [
        // The 13-inch frame first: the capture is a 13-inch iPad, and the
        // 11-inch cut-out has a different aspect ratio.
        "*iPad*Air*13*Portrait*.png",
        "*iPad*13*Portrait*.png",
        "*iPad*Air*Portrait*.png",
        "*iPad*Portrait*.png",
        "*iPad*.png",
    ]),
    // Landscape: Apple's Mac bezels frame a whole display.
    Subject(name: "mac-window", bezelPatterns: [
        "*MacBook*Pro*.png",
        "*iMac*.png",
        "*MacBook*.png",
    ]),
    Subject(name: "tv-play", bezelPatterns: [
        "*Apple*TV*.png",
    ]),
    Subject(name: "watch-board", bezelPatterns: [
        // The 46 mm frame first: the capture is the 46 mm simulator.
        "*Watch*S11*46mm*.png",
        "*Watch*46mm*.png",
        "*Watch*Series*11*.png",
        "*Watch*.png",
    ]),
    Subject(name: "vision-volume", bezelPatterns: []),
]

/// Optional `bezels/bezels.json`, for when Apple renames a package or a bezel
/// turns out to have an OPAQUE screen (some Photoshop exports do) and the flood
/// fill has nothing to find:
///
///     {
///       "iphone-board": { "patterns": ["*iPhone 17*.png"] },
///       "watch-board":  { "screenRect": [x, y, width, height] }
///     }
///
/// `screenRect` is in bezel pixels, top-left origin, and skips the fill.
struct BezelOverride: Decodable {
    let patterns: [String]?
    let screenRect: [Int]?
}

// MARK: - Small helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func note(_ message: String) {
    print(message)
    fflush(stdout)
}

/// Case-insensitive shell-style glob (`*` and `?` only) over a file name.
func globMatches(_ name: String, pattern: String) -> Bool {
    var regex = "^"
    for character in pattern {
        switch character {
        case "*": regex += ".*"
        case "?": regex += "."
        default: regex += NSRegularExpression.escapedPattern(for: String(character))
        }
    }
    regex += "$"
    return name.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: - Pixel buffers
//
// Everything below works on RGBA8 premultiplied-last buffers produced by ONE
// helper (`rasterize`). Bezel, capture and composite therefore share a row
// convention by construction, so no vertical-flip bookkeeping is needed: any
// global flip cancels out when the composite goes back through the same
// CoreGraphics path on the way out.

struct Raster {
    var width: Int
    var height: Int
    var pixels: [UInt8]   // RGBA, premultiplied, row-major, 4 bytes per pixel

    subscript(x: Int, y: Int) -> Int { (y * width + x) * 4 }
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

func makeContext(width: Int, height: Int) -> CGContext? {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)
}

func rasterize(_ image: CGImage, width: Int, height: Int, in rect: CGRect) -> Raster {
    guard let context = makeContext(width: width, height: height) else {
        fail("could not allocate a \(width)x\(height) bitmap")
    }
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    guard let data = context.data else { fail("bitmap context had no backing store") }
    let count = width * height * 4
    let buffer = UnsafeRawBufferPointer(start: data, count: count)
    return Raster(width: width, height: height, pixels: [UInt8](buffer))
}

func rasterize(_ image: CGImage) -> Raster {
    rasterize(image, width: image.width, height: image.height,
              in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
}

func makeImage(_ raster: Raster) -> CGImage {
    guard let context = makeContext(width: raster.width, height: raster.height),
          let destination = context.data else {
        fail("could not allocate the output bitmap")
    }
    raster.pixels.withUnsafeBytes { source in
        destination.copyMemory(from: source.baseAddress!, byteCount: source.count)
    }
    guard let image = context.makeImage() else { fail("could not build the output image") }
    return image
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("could not read an image from \(url.path)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not create a PNG writer for \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("could not write \(url.path)")
    }
}

// MARK: - Screen cut-out

struct Mask {
    var flags: [Bool]
    var minX: Int, minY: Int, maxX: Int, maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

/// Scanline flood fill over `alpha == 0`, seeded at the image centre.
///
/// Scanline rather than a per-pixel stack: a 4000x8000 bezel is 32 million
/// pixels, and a naive stack of every candidate would cost more memory than the
/// image itself.
func floodFillScreen(_ raster: Raster) -> Mask? {
    let width = raster.width, height = raster.height
    let seedX = width / 2, seedY = height / 2
    guard raster.pixels[raster[seedX, seedY] + 3] == 0 else { return nil }

    var flags = [Bool](repeating: false, count: width * height)
    var minX = width, minY = height, maxX = 0, maxY = 0
    var stack: [(Int, Int)] = [(seedX, seedY)]

    func isOpen(_ x: Int, _ y: Int) -> Bool {
        !flags[y * width + x] && raster.pixels[raster[x, y] + 3] == 0
    }

    while let point = stack.popLast() {
        let (seed, row) = point
        guard isOpen(seed, row) else { continue }
        var left = seed
        while left > 0, isOpen(left - 1, row) { left -= 1 }
        var right = seed
        while right < width - 1, isOpen(right + 1, row) { right += 1 }

        for x in left...right { flags[row * width + x] = true }
        minX = min(minX, left); maxX = max(maxX, right)
        minY = min(minY, row);  maxY = max(maxY, row)

        for neighbour in [row - 1, row + 1] where neighbour >= 0 && neighbour < height {
            var x = left
            while x <= right {
                if isOpen(x, neighbour) {
                    stack.append((x, neighbour))
                    while x <= right, isOpen(x, neighbour) { x += 1 }
                }
                x += 1
            }
        }
    }
    return Mask(flags: flags, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

/// Separable dilation (horizontal pass, then vertical): 2 * (2r + 1) reads per
/// pixel instead of (2r + 1)^2.
func dilate(_ mask: Mask, radius: Int, width: Int, height: Int) -> [Bool] {
    guard radius > 0 else { return mask.flags }
    var horizontal = [Bool](repeating: false, count: width * height)
    for y in 0..<height {
        let row = y * width
        for x in 0..<width where mask.flags[row + x] {
            let from = max(0, x - radius), to = min(width - 1, x + radius)
            for xx in from...to { horizontal[row + xx] = true }
        }
    }
    var out = [Bool](repeating: false, count: width * height)
    for y in 0..<height {
        let row = y * width
        for x in 0..<width where horizontal[row + x] {
            let from = max(0, y - radius), to = min(height - 1, y + radius)
            for yy in from...to { out[yy * width + x] = true }
        }
    }
    return out
}

// MARK: - Compositing

/// Scale `capture` to COVER `rect` (centred, overflow cropped) inside a buffer
/// the size of the bezel.
func placeCapture(_ capture: CGImage, bezelWidth: Int, bezelHeight: Int,
                  rect: (x: Int, y: Int, width: Int, height: Int)) -> Raster {
    let scale = max(Double(rect.width) / Double(capture.width),
                    Double(rect.height) / Double(capture.height))
    let drawWidth = Double(capture.width) * scale
    let drawHeight = Double(capture.height) * scale
    // Buffer coordinates and CoreGraphics coordinates disagree about which way
    // is up, but the placement is CENTRED in both, so the same expression is
    // correct either way — the only asymmetry, the row offset of the rect
    // inside the bezel, is measured in buffer coordinates below and never here.
    let originX = Double(rect.x) + (Double(rect.width) - drawWidth) / 2
    let originY = Double(bezelHeight - rect.y - rect.height)
        + (Double(rect.height) - drawHeight) / 2
    return rasterize(capture, width: bezelWidth, height: bezelHeight,
                     in: CGRect(x: originX, y: originY, width: drawWidth, height: drawHeight))
}

/// Bezel OVER capture, but only where the (dilated) screen mask says there is a
/// screen. Everything else is the bezel untouched — including the transparency
/// outside the device outline, which is what gives the committed PNG its
/// cut-out silhouette.
func composite(bezel: Raster, capture: Raster, mask: [Bool]) -> Raster {
    var out = bezel
    for index in 0..<(bezel.width * bezel.height) where mask[index] {
        let offset = index * 4
        let topAlpha = Int(bezel.pixels[offset + 3])
        guard topAlpha < 255 else { continue }
        let inverse = 255 - topAlpha
        for channel in 0..<4 {
            let top = Int(bezel.pixels[offset + channel])
            let bottom = Int(capture.pixels[offset + channel])
            out.pixels[offset + channel] = UInt8(min(255, top + (bottom * inverse + 127) / 255))
        }
    }
    return out
}

func resize(_ image: CGImage, toWidth width: Int) -> CGImage {
    let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
    let raster = rasterize(image, width: width, height: height,
                           in: CGRect(x: 0, y: 0, width: width, height: height))
    return makeImage(raster)
}

// MARK: - Size budget

/// Through FileManager, NOT `url.resourceValues`: Foundation caches resource
/// values on the URL value, so a second read after rewriting the file returned
/// the FIRST file's size and the width step-down below ran to its floor on a
/// stale number.
func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? Int.max
}

func hasPngquant() -> Bool {
    FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pngquant")
        || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/pngquant")
}

@discardableResult
func runPngquant(on url: URL) -> Bool {
    let path = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pngquant")
        ? "/opt/homebrew/bin/pngquant" : "/usr/local/bin/pngquant"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--quality", "70-95", "--speed", "1", "--force",
                         "--output", url.path, "--", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    // 99 = "quality fell below the floor"; pngquant then leaves the file alone,
    // which is the right answer — the width step-down below takes over.
    return process.terminationStatus == 0
}

/// Write `image` at successively narrower widths until the PNG fits the cap.
func writeWithinBudget(_ image: CGImage, to url: URL, subject: String) {
    var width = min(defaultOutputWidth, image.width)
    while width >= minOutputWidth {
        writePNG(resize(image, toWidth: width), to: url)
        var size = fileSize(url)
        if size > maxBytes, hasPngquant() {
            runPngquant(on: url)
            size = fileSize(url)
        }
        if size <= maxBytes {
            let kilobytes = (size + 512) / 1024
            let flag = size > targetBytes ? "  (over the \(targetBytes / 1024) KB target)" : ""
            note("  wrote \(url.path)  \(width) px, \(kilobytes) KB\(flag)")
            return
        }
        note("  \(subject): \(width) px is \((size + 512) / 1024) KB, over the "
             + "\(maxBytes / 1024) KB cap — retrying 100 px narrower")
        width -= 100
    }
    fail("\(subject) could not be squeezed under \(maxBytes / 1024) KB at \(minOutputWidth) px. "
         + "Install pngquant (`brew install pngquant`) or simplify the captured screen.")
}

// MARK: - `window` subcommand

func runWindowSubcommand(owner: String) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        fail("CGWindowListCopyWindowInfo returned nothing")
    }
    // The Screen Recording pre-flight: kCGWindowName is redacted for OTHER
    // processes' windows unless the permission is held. Our own windows always
    // report a name, so they are excluded from the probe.
    let myPID = Int(ProcessInfo.processInfo.processIdentifier)
    let foreignNamed = windows.contains { window in
        let pid = window[kCGWindowOwnerPID as String] as? Int ?? myPID
        return pid != myPID && (window[kCGWindowName as String] as? String)?.isEmpty == false
    }
    print("SCREEN_RECORDING=\(foreignNamed ? "granted" : "denied")")

    let candidates = windows.filter {
        ($0[kCGWindowOwnerName as String] as? String) == owner
            && (($0[kCGWindowLayer as String] as? Int) ?? 0) == 0
    }
    func area(_ window: [String: Any]) -> Double {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else { return 0 }
        return width * height
    }
    guard let biggest = candidates.max(by: { area($0) < area($1) }),
          let number = biggest[kCGWindowNumber as String] as? Int else {
        print("WINDOW_ID=")
        return
    }
    print("WINDOW_ID=\(number)")
}

// MARK: - `frame` subcommand

func runFrameSubcommand(rawDir: URL, bezelsDir: URL, outDir: URL) {
    let manager = FileManager.default
    try? manager.createDirectory(at: outDir, withIntermediateDirectories: true)

    var overrides: [String: BezelOverride] = [:]
    let overrideURL = bezelsDir.appendingPathComponent("bezels.json")
    if let data = try? Data(contentsOf: overrideURL) {
        guard let decoded = try? JSONDecoder().decode([String: BezelOverride].self, from: data) else {
            fail("\(overrideURL.path) is not valid JSON of the documented shape")
        }
        overrides = decoded
        note("using bezel overrides from \(overrideURL.path)")
    }

    let bezelFiles: [URL] = (manager.enumerator(at: bezelsDir, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension.lowercased() == "png" }) ?? []

    for subject in subjects {
        let rawURL = rawDir.appendingPathComponent("\(subject.name).png")
        guard manager.fileExists(atPath: rawURL.path) else {
            note("skipping \(subject.name): no raw capture at \(rawURL.path)")
            continue
        }
        let outURL = outDir.appendingPathComponent("\(subject.name).png")
        let override = overrides[subject.name]
        let patterns = override?.patterns ?? subject.bezelPatterns

        guard !patterns.isEmpty else {
            note("\(subject.name): unframed by design (no Apple bezel exists for this device)")
            writeWithinBudget(loadImage(rawURL), to: outURL, subject: subject.name)
            continue
        }

        guard let bezelURL = patterns.lazy.compactMap({ pattern in
            bezelFiles.first { globMatches($0.lastPathComponent, pattern: pattern) }
        }).first else {
            let present = bezelFiles.isEmpty
                ? "  (bezels/ holds no .png files at all)"
                : bezelFiles.map { "  " + $0.lastPathComponent }.sorted().joined(separator: "\n")
            fail("""
                 no bezel for \(subject.name). Tried, in order:
                 \(patterns.map { "  " + $0 }.joined(separator: "\n"))
                 What is in \(bezelsDir.path):
                 \(present)
                 See bezels/README.md for which Apple Design Resources package to download,
                 or add a "patterns" override to bezels/bezels.json.
                 """)
        }

        note("\(subject.name): \(bezelURL.lastPathComponent)")
        let bezelImage = loadImage(bezelURL)
        let bezel = rasterize(bezelImage)

        let rect: (x: Int, y: Int, width: Int, height: Int)
        var maskFlags: [Bool]
        if let explicit = override?.screenRect, explicit.count == 4 {
            rect = (explicit[0], explicit[1], explicit[2], explicit[3])
            maskFlags = [Bool](repeating: false, count: bezel.width * bezel.height)
            for y in rect.y..<min(bezel.height, rect.y + rect.height) {
                for x in rect.x..<min(bezel.width, rect.x + rect.width) {
                    maskFlags[y * bezel.width + x] = true
                }
            }
        } else {
            guard let mask = floodFillScreen(bezel) else {
                fail("""
                     \(bezelURL.lastPathComponent): the centre pixel is OPAQUE, so the screen
                     cut-out cannot be found by flood fill. Either this bezel export has a filled
                     screen (open the .psd and export the bezel layer alone), or the file is not a
                     bezel at all. As a last resort, put a "screenRect": [x, y, width, height]
                     entry for \(subject.name) in bezels/bezels.json.
                     """)
            }
            rect = (mask.minX, mask.minY, mask.width, mask.height)
            maskFlags = dilate(mask, radius: maskDilation, width: bezel.width, height: bezel.height)
        }
        note("  screen cut-out: \(rect.width)x\(rect.height) at (\(rect.x), \(rect.y))")

        let captureImage = loadImage(rawURL)
        let capture = placeCapture(captureImage, bezelWidth: bezel.width,
                                   bezelHeight: bezel.height, rect: rect)
        let framed = composite(bezel: bezel, capture: capture, mask: maskFlags)
        writeWithinBudget(makeImage(framed), to: outURL, subject: subject.name)
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "window":
    guard arguments.count == 2 else { fail("usage: frame_screenshots.swift window <owner-name>") }
    runWindowSubcommand(owner: arguments[1])

case "frame", nil:
    let rest = arguments.first == "frame" ? Array(arguments.dropFirst()) : arguments
    guard rest.count == 3 else {
        fail("usage: frame_screenshots.swift frame <rawDir> <bezelsDir> <outDir>")
    }
    runFrameSubcommand(rawDir: URL(fileURLWithPath: rest[0]),
                       bezelsDir: URL(fileURLWithPath: rest[1]),
                       outDir: URL(fileURLWithPath: rest[2]))

default:
    fail("""
         usage:
           frame_screenshots.swift frame <rawDir> <bezelsDir> <outDir>
           frame_screenshots.swift window <owner-name>
         """)
}
