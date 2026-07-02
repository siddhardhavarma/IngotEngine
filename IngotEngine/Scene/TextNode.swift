//
//  TextNode.swift
//  IngotEngine
//
//  §4.4 Scene System — Renders text as a textured quad.
//
//  TextNode renders a string into a CGBitmapContext using Core Text,
//  then uploads it as an MTLTexture. The existing sprite pipeline draws
//  it like any other textured quad. This avoids the complexity of a
//  font atlas system — suitable for labels, scores, and UI text.
//
//  Uses only CoreText + CoreGraphics (no AppKit/UIKit), so the same
//  file compiles on macOS, iOS, and tvOS — exported games render text
//  identically to the editor.
//
//  Performance note: the texture is regenerated only when `text`,
//  `fontSize`, or `textColor` changes, not every frame.
//

import CoreGraphics
import CoreText
import Foundation
import MetalKit
import simd

class TextNode: SpriteNode {

    /// The text string to display.
    var text: String = "Hello" {
        didSet { if text != oldValue { needsRedraw = true } }
    }

    /// Font size in points.
    var fontSize: CGFloat = 24 {
        didSet { if fontSize != oldValue { needsRedraw = true } }
    }

    /// Text color (RGBA, 0–1).
    var textColor = simd_float4(1, 1, 1, 1) {
        didSet { needsRedraw = true }
    }

    private var needsRedraw = true
    private weak var cachedDevice: MTLDevice?

    override init() {
        super.init()
        name = "Text"
    }

    /// Regenerates the text texture if the text or style has changed.
    /// Called lazily by the renderer before drawing.
    func ensureTexture(device: MTLDevice) {
        guard needsRedraw || texture == nil || cachedDevice !== device else { return }

        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgColor = CGColor(colorSpace: colorSpace,
                                    components: [CGFloat(textColor.x), CGFloat(textColor.y),
                                                 CGFloat(textColor.z), CGFloat(textColor.w)]) else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)

        // Measure the line.
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let width = max(Int(ceil(advance)), 1)
        let height = max(Int(ceil(ascent + descent)), 1)

        // Draw into an RGBA bitmap context.
        guard let context = CGContext(data: nil,
                                      width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return
        }

        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else { return }

        // Upload to Metal.
        let loader = MTKTextureLoader(device: device)
        if let tex = try? loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false as NSNumber
        ]) {
            texture = tex
            cachedDevice = device
            needsRedraw = false

            // Scale the quad to match the text dimensions.
            scale = simd_float2(Float(width) / 100.0, Float(height) / 100.0)
        }
    }
}
