import CoreGraphics
import Foundation

/// The four material backdrops of the Saved Game widget: full-bleed
/// procedural textures the board's wood card sits on. Wood itself stays in
/// `WidgetWoodTexture` (it doubles as the board card's grain); these exist
/// only as backplates.
public enum WidgetBackplateMaterial: CaseIterable, Sendable {
    case grass, tatami, slate, sky

    /// Flat stand-in near the texture's average color — what the widget
    /// paints if CGImage creation ever fails, parity with the wood fallback
    /// (`WidgetBoardStyle.gobanWood`).
    public var baseColor: WidgetBoardStyle.RGB {
        switch self {
        case .grass: WidgetBoardStyle.RGB(red: 56 / 255, green: 108 / 255, blue: 52 / 255)
        case .tatami: WidgetBoardStyle.RGB(red: 206 / 255, green: 188 / 255, blue: 142 / 255)
        case .slate: WidgetBoardStyle.RGB(red: 60 / 255, green: 62 / 255, blue: 66 / 255)
        case .sky: WidgetBoardStyle.RGB(red: 148 / 255, green: 188 / 255, blue: 233 / 255)
        }
    }
}

/// Backplate-texture door for the material backdrops, on the exact contract
/// of `WidgetWoodTexture`: generation clamped to the appex-safe pixel cap
/// (the widget process has a hard 30 MB jetsam limit), fully deterministic
/// (fixed-seed noise, no clock or unseeded randomness), and one memoized
/// CGImage per material — generated lazily, only for a material a widget
/// actually shows.
public enum WidgetBackplateTexture {
    /// Requested material texture, clamped to `WidgetWoodTexture.maxSidePX`
    /// per side (one cap for every widget texture).
    public static func texture(_ material: WidgetBackplateMaterial,
                               widthPX: Int, heightPX: Int) -> BoardTopTexture {
        let w = min(max(widthPX, 1), WidgetWoodTexture.maxSidePX)
        let h = min(max(heightPX, 1), WidgetWoodTexture.maxSidePX)
        switch material {
        case .grass: return generateGrass(widthPX: w, heightPX: h)
        case .tatami: return generateTatami(widthPX: w, heightPX: h)
        case .slate: return generateSlate(widthPX: w, heightPX: h)
        case .sky: return generateSky(widthPX: w, heightPX: h)
        }
    }

    @MainActor private static var cachedImages: [WidgetBackplateMaterial: CGImage] = [:]

    /// The shared square image for one material — memoized so GeometryReader
    /// relayouts never regenerate the pixel buffer, and keyed per material so
    /// only the requested backdrop is ever generated.
    @MainActor public static func sharedSquareImage(_ material: WidgetBackplateMaterial) -> CGImage? {
        if let cached = cachedImages[material] { return cached }
        let image = texture(material,
                            widthPX: WidgetWoodTexture.maxSidePX,
                            heightPX: WidgetWoodTexture.maxSidePX).cgImage
        cachedImages[material] = image
        return image
    }

    // MARK: - Generators

    /// Writes one clamped RGB pixel; alpha stays the buffer's initial 255.
    private static func store(_ pixels: inout [UInt8], _ offset: Int,
                              _ r: Double, _ g: Double, _ b: Double) {
        pixels[offset] = UInt8(min(max(r, 0), 255))
        pixels[offset + 1] = UInt8(min(max(g, 0), 255))
        pixels[offset + 2] = UInt8(min(max(b, 0), 255))
    }

    /// Lawn: mottled midtone green (low-frequency sines + seeded jitter, the
    /// wood grain's recipe in green) with short blade strokes scattered on
    /// top, half catching light and half in shade.
    private static func generateGrass(widthPX w: Int, heightPX h: Int) -> BoardTopTexture {
        var rng = SplitMix64(seed: 0x4752_4153) // "GRAS"
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let rowBase = y * w
            for x in 0..<w {
                let mottle = 6 * sin(Double(x) * 0.031 + Double(y) * 0.017)
                    + 4 * sin(Double(x) * 0.011 - Double(y) * 0.023 + 1.3)
                let jitter = (rng.next() - 0.5) * 10
                store(&pixels, (rowBase + x) * 4,
                      56 + mottle * 0.5 + jitter * 0.6,
                      108 + mottle + jitter,
                      52 + mottle * 0.4 + jitter * 0.5)
            }
        }
        // Blades: short, mostly upright strokes fading toward the tip.
        let bladeCount = max(w * h / 180, 1)
        for _ in 0..<bladeCount {
            let x0 = rng.next() * Double(w)
            let y0 = rng.next() * Double(h)
            let length = 6 + Int(rng.next() * 10)
            let lean = (rng.next() - 0.5) * 0.9
            let delta = rng.next() < 0.5 ? 26.0 : -22.0
            for t in 0..<length {
                let x = Int((x0 + lean * Double(t)).rounded())
                let y = Int((y0 - Double(t)).rounded())
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let fade = 1 - Double(t) / Double(length)
                let offset = (y * w + x) * 4
                store(&pixels, offset,
                      Double(pixels[offset]) + delta * 0.6 * fade,
                      Double(pixels[offset + 1]) + delta * fade,
                      Double(pixels[offset + 2]) + delta * 0.4 * fade)
            }
        }
        return BoardTopTexture(widthPX: w, heightPX: h, pixels: pixels)
    }

    /// Woven straw mat: horizontal weave bands whose fine ribs alternate
    /// direction band to band (the over-under read), darker stitch rows at
    /// each band boundary, all low-contrast so ink text stays legible.
    private static func generateTatami(widthPX w: Int, heightPX h: Int) -> BoardTopTexture {
        var rng = SplitMix64(seed: 0x5441_5441) // "TATA"
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let bandHeight = max(h / 6, 8)
        for y in 0..<h {
            let band = y / bandHeight
            let rowBase = y * w
            let isStitchRow = y % bandHeight <= 1
            for x in 0..<w {
                // ~3 px straw ribs, run direction alternating per band.
                let rib = band % 2 == 0
                    ? 7 * sin(Double(x) * 1.9)
                    : 7 * sin(Double(y) * 1.9)
                let sheen = 3 * sin(Double(y) * 0.9 + Double(band))
                let jitter = (rng.next() - 0.5) * 6
                let stitch = isStitchRow ? -18.0 : 0
                store(&pixels, (rowBase + x) * 4,
                      206 + rib + sheen + jitter + stitch,
                      188 + rib * 0.95 + sheen + jitter + stitch,
                      142 + rib * 0.8 + sheen * 0.8 + jitter * 0.8 + stitch)
            }
        }
        return BoardTopTexture(widthPX: w, heightPX: h, pixels: pixels)
    }

    /// Dark stone: near-neutral gray with broad tonal drift and a few pale
    /// veins wandering down the slab.
    private static func generateSlate(widthPX w: Int, heightPX h: Int) -> BoardTopTexture {
        var rng = SplitMix64(seed: 0x534C_4154) // "SLAT"
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let rowBase = y * w
            for x in 0..<w {
                let drift = 5 * sin(Double(x) * 0.013 + Double(y) * 0.007)
                    + 4 * sin(Double(x) * 0.005 - Double(y) * 0.011 + 2.0)
                let jitter = (rng.next() - 0.5) * 8
                let tone = drift + jitter
                store(&pixels, (rowBase + x) * 4,
                      60 + tone, 62 + tone, 66 + tone)
            }
        }
        // Veins: top-to-bottom random walks, a 2 px pale streak with a dimmer
        // halo pixel on each side.
        let veinCount = max((w + h) / 160, 2)
        for _ in 0..<veinCount {
            var x = rng.next() * Double(w)
            let drift = (rng.next() - 0.5) * 1.2
            for y in 0..<h {
                x += drift + (rng.next() - 0.5) * 1.4
                let cx = Int(x.rounded())
                for (dx, lift) in [(0, 22.0), (-1, 10.0), (1, 10.0)] {
                    let px = cx + dx
                    guard px >= 0, px < w else { continue }
                    let offset = (y * w + px) * 4
                    store(&pixels, offset,
                          Double(pixels[offset]) + lift,
                          Double(pixels[offset + 1]) + lift,
                          Double(pixels[offset + 2]) + lift)
                }
            }
        }
        return BoardTopTexture(widthPX: w, heightPX: h, pixels: pixels)
    }

    /// Sky: vertical gradient from deeper blue at the top to a pale horizon,
    /// with a few soft clouds — clusters of gaussian blobs blended toward
    /// white — floating in the upper half.
    private static func generateSky(widthPX w: Int, heightPX h: Int) -> BoardTopTexture {
        var rng = SplitMix64(seed: 0x534B_5920) // "SKY "
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let top = (r: 108.0, g: 160.0, b: 224.0)
        let bottom = (r: 188.0, g: 216.0, b: 242.0)
        for y in 0..<h {
            let t = h > 1 ? Double(y) / Double(h - 1) : 0
            let rowBase = y * w
            for x in 0..<w {
                store(&pixels, (rowBase + x) * 4,
                      top.r + (bottom.r - top.r) * t,
                      top.g + (bottom.g - top.g) * t,
                      top.b + (bottom.b - top.b) * t)
            }
        }
        for _ in 0..<3 {
            let centerX = rng.next() * Double(w)
            let centerY = rng.next() * Double(h) * 0.5
            let cloudRadius = Double(min(w, h)) * (0.05 + rng.next() * 0.04)
            for _ in 0..<5 {
                let blobX = centerX + (rng.next() - 0.5) * cloudRadius * 2.4
                let blobY = centerY + (rng.next() - 0.5) * cloudRadius * 0.8
                let blobRadius = cloudRadius * (0.5 + rng.next() * 0.5)
                let x0 = max(Int(blobX - blobRadius * 2), 0)
                let x1 = min(Int(blobX + blobRadius * 2) + 1, w)
                let y0 = max(Int(blobY - blobRadius * 2), 0)
                let y1 = min(Int(blobY + blobRadius * 2) + 1, h)
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let dx = Double(x) - blobX
                        let dy = Double(y) - blobY
                        let alpha = 0.45 * exp(-(dx * dx + dy * dy) / (blobRadius * blobRadius))
                        let offset = (y * w + x) * 4
                        store(&pixels, offset,
                              Double(pixels[offset]) + (250 - Double(pixels[offset])) * alpha,
                              Double(pixels[offset + 1]) + (250 - Double(pixels[offset + 1])) * alpha,
                              Double(pixels[offset + 2]) + (252 - Double(pixels[offset + 2])) * alpha)
                    }
                }
            }
        }
        return BoardTopTexture(widthPX: w, heightPX: h, pixels: pixels)
    }
}

/// Deterministic uniform stream in [0, 1): SplitMix64, the same generator
/// family as `BoardTopTexture`'s grain noise (whose Gaussian wrapper is
/// private to that file).
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) * 0x1p-53
    }
}
