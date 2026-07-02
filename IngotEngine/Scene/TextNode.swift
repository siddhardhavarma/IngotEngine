//
//  TextNode.swift
//  IngotEngine
//
//  §4.4 Scene System — Renders text as a textured quad.
//
//  TextNode renders a string to an offscreen NSImage using Core Text,
//  then uploads it as an MTLTexture. The existing sprite pipeline draws
//  it like any other textured quad. This avoids the complexity of a
//  font atlas system — suitable for labels, scores, and UI text.
//
//  Performance note: the texture is regenerated only when `text`,
//  `fontSize`, or `textColor` changes, not every frame.
//

import Cocoa
import MetalKit

class TextNode: SpriteNode {

    /// The text string to display.
    var text: String = "Hello" {
        didSet { if text != oldValue { needsRedraw = true } }
    }

    /// Font size in points.
    var fontSize: CGFloat = 24 {
        didSet { if fontSize != oldValue { needsRedraw = true } }
    }

    /// Text color.
    var textColor: NSColor = .white {
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

        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]

        // Measure the text size.
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let size = attrString.size()

        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)

        // Render text to an NSImage.
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        attrString.draw(at: .zero)
        image.unlockFocus()

        // Convert NSImage to CGImage to get raw pixel data.
        guard let cgImage = image.cgImage(forProposedRect: nil,
                                           context: nil,
                                           hints: nil) else { return }

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
