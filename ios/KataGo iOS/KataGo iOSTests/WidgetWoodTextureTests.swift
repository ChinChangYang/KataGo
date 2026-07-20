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
