//
//  WidgetWoodTextureTests.swift
//  KataGo AnytimeTests
//
//  The widget-side wood image: the goban's exact procedural grain, but
//  WITHOUT grid/hoshi ink (the widget keeps those vector, drawn on top) and
//  hard-capped in size — the full-res BoardTopTexture.generate for 19x19 is
//  a 2048-px image whose pixel buffer + CGImage would blow the appex's hard
//  30 MB jetsam limit. Probe thresholds mirror BoardTopTextureTests: wood
//  reads R > 170, ink reads R < 130.
//

import Foundation
import Testing
import KataGoGameStore

struct WidgetWoodTextureTests {
    @Test func woodOnlyHasNoInkAnywhere() {
        let texture = BoardTopTexture.generateWood(widthPX: 128, heightPX: 128)
        var minRed = 255
        for i in stride(from: 0, to: texture.pixels.count, by: 4) {
            minRed = min(minRed, Int(texture.pixels[i]))
        }
        #expect(minRed > 170)
    }

    @Test func woodGenerationIsDeterministic() {
        let first = BoardTopTexture.generateWood(widthPX: 128, heightPX: 96)
        let second = BoardTopTexture.generateWood(widthPX: 128, heightPX: 96)
        #expect(first.pixels == second.pixels)
    }

    @Test func woodDimensionsAreRespected() {
        let texture = BoardTopTexture.generateWood(widthPX: 100, heightPX: 60)
        #expect(texture.widthPX == 100)
        #expect(texture.heightPX == 60)
        #expect(texture.pixels.count == 100 * 60 * 4)
    }

    @Test func woodIsFullyOpaque() {
        let texture = BoardTopTexture.generateWood(widthPX: 64, heightPX: 64)
        for i in stride(from: 3, to: texture.pixels.count, by: 4) {
            #expect(texture.pixels[i] == 255)
        }
    }

    @Test func textureClampsToTheJetsamSafeCap() {
        // 640*640*4 B = 1.6 MB — a request for a full-res-sized image must be
        // clamped, never honored, inside the memory-capped appex.
        #expect(WidgetWoodTexture.maxSidePX == 640)
        let texture = WidgetWoodTexture.texture(widthPX: 4096, heightPX: 4096)
        #expect(texture.widthPX == WidgetWoodTexture.maxSidePX)
        #expect(texture.heightPX == WidgetWoodTexture.maxSidePX)
    }

    @Test func textureMatchesGenerateWoodWithinTheCap() {
        let viaCap = WidgetWoodTexture.texture(widthPX: 128, heightPX: 96)
        let direct = BoardTopTexture.generateWood(widthPX: 128, heightPX: 96)
        #expect(viaCap.pixels == direct.pixels)
    }

    @Test @MainActor func sharedSquareImageIsMemoized() {
        // GeometryReader relayouts call this on every pass — it must hand back
        // the SAME CGImage instance, not regenerate 1.6 MB of pixels.
        let first = WidgetWoodTexture.sharedSquareImage()
        let second = WidgetWoodTexture.sharedSquareImage()
        #expect(first != nil)
        #expect(first === second)
        #expect(first?.width == WidgetWoodTexture.maxSidePX)
        #expect(first?.height == WidgetWoodTexture.maxSidePX)
    }
}

/// The four material backdrops (Grass, Tatami, Slate, Sky) ride the same
/// contract as the wood: procedural, seeded-deterministic, clamped to the
/// appex-safe cap, fully opaque, memoized per material.
struct WidgetBackplateTextureTests {
    @Test(arguments: WidgetBackplateMaterial.allCases)
    func materialGenerationIsDeterministic(material: WidgetBackplateMaterial) {
        let first = WidgetBackplateTexture.texture(material, widthPX: 128, heightPX: 96)
        let second = WidgetBackplateTexture.texture(material, widthPX: 128, heightPX: 96)
        #expect(first.pixels == second.pixels)
        #expect(first.widthPX == 128)
        #expect(first.heightPX == 96)
        #expect(first.pixels.count == 128 * 96 * 4)
    }

    @Test(arguments: WidgetBackplateMaterial.allCases)
    func materialTextureClampsToTheJetsamSafeCap(material: WidgetBackplateMaterial) {
        // Same hard cap as the wood: a full-res-sized request must be clamped,
        // never honored, inside the memory-capped appex.
        let texture = WidgetBackplateTexture.texture(material, widthPX: 4096, heightPX: 4096)
        #expect(texture.widthPX == WidgetWoodTexture.maxSidePX)
        #expect(texture.heightPX == WidgetWoodTexture.maxSidePX)
    }

    @Test func materialBaseColorsArePinnedForTheFailurePathFallback() {
        // The flat color the widget paints when CGImage creation fails —
        // pinned like gobanWood so a refactor can't quietly swap, say,
        // slate's near-black for sky's pale blue under the plan's scheme pin.
        #expect(WidgetBackplateMaterial.grass.baseColor
            == WidgetBoardStyle.RGB(red: 56 / 255, green: 108 / 255, blue: 52 / 255))
        #expect(WidgetBackplateMaterial.tatami.baseColor
            == WidgetBoardStyle.RGB(red: 206 / 255, green: 188 / 255, blue: 142 / 255))
        #expect(WidgetBackplateMaterial.slate.baseColor
            == WidgetBoardStyle.RGB(red: 60 / 255, green: 62 / 255, blue: 66 / 255))
        #expect(WidgetBackplateMaterial.sky.baseColor
            == WidgetBoardStyle.RGB(red: 148 / 255, green: 188 / 255, blue: 233 / 255))
    }

    @Test(arguments: WidgetBackplateMaterial.allCases)
    func materialTextureIsFullyOpaque(material: WidgetBackplateMaterial) {
        let texture = WidgetBackplateTexture.texture(material, widthPX: 64, heightPX: 64)
        for i in stride(from: 3, to: texture.pixels.count, by: 4) {
            #expect(texture.pixels[i] == 255)
        }
    }

    /// Channel means of an RGBA8 texture, for the identity probes below.
    private func mean(_ texture: BoardTopTexture,
                      rows: Range<Int>? = nil) -> (r: Double, g: Double, b: Double) {
        let rowRange = rows ?? 0..<texture.heightPX
        var r = 0.0, g = 0.0, b = 0.0
        var count = 0.0
        for y in rowRange {
            let rowBase = y * texture.widthPX * 4
            for x in 0..<texture.widthPX {
                let offset = rowBase + x * 4
                r += Double(texture.pixels[offset])
                g += Double(texture.pixels[offset + 1])
                b += Double(texture.pixels[offset + 2])
                count += 1
            }
        }
        return (r / count, g / count, b / count)
    }

    @Test func materialsReadAsTheirMaterials() {
        // Coarse identity probes so a seed or palette regression can't quietly
        // ship a texture that no longer reads as its picker title.
        let grass = mean(WidgetBackplateTexture.texture(.grass, widthPX: 128, heightPX: 128))
        #expect(grass.g > grass.r + 20)   // green-dominant lawn
        #expect(grass.g > grass.b + 20)

        let tatami = mean(WidgetBackplateTexture.texture(.tatami, widthPX: 128, heightPX: 128))
        #expect(tatami.r > 180)           // pale straw, light enough for ink text
        #expect(tatami.r > tatami.b + 40) // warm, not gray

        let slate = mean(WidgetBackplateTexture.texture(.slate, widthPX: 128, heightPX: 128))
        #expect(slate.g < 100)            // dark stone, bright text on top
        #expect(abs(slate.r - slate.b) < 15) // near-neutral gray, not tinted

        let sky = mean(WidgetBackplateTexture.texture(.sky, widthPX: 128, heightPX: 128))
        #expect(sky.b > sky.r + 15)       // blue-dominant
        #expect(sky.b > 180)              // light enough for ink text
    }

    @Test func skyGradientDeepensTowardTheTop() {
        // The sky is a soft vertical gradient: deeper blue up top, paler at
        // the horizon — probed as the top quarter reading darker (lower red)
        // than the bottom quarter, clouds included.
        let texture = WidgetBackplateTexture.texture(.sky, widthPX: 128, heightPX: 128)
        let top = mean(texture, rows: 0..<32)
        let bottom = mean(texture, rows: 96..<128)
        #expect(top.r + 20 < bottom.r)
    }

    @Test @MainActor func materialSharedSquareImageIsMemoizedPerMaterial() {
        // Same relayout contract as the wood — and each material is generated
        // lazily, only when a widget actually requests it.
        let first = WidgetBackplateTexture.sharedSquareImage(.slate)
        let second = WidgetBackplateTexture.sharedSquareImage(.slate)
        #expect(first != nil)
        #expect(first === second)
        #expect(first?.width == WidgetWoodTexture.maxSidePX)
        #expect(first?.height == WidgetWoodTexture.maxSidePX)

        let other = WidgetBackplateTexture.sharedSquareImage(.sky)
        #expect(other != nil)
        #expect(other !== first)
    }
}
