#if os(iOS)
    import CoreText
    import Metal
    import UIKit

    /// Everything a sprite's pixels depend on; overlays that share one reuse its texture.
    struct TextSpriteKey: Hashable {
        let text: String
        let fontPixels: Int
        let wrapPixels: Int
        let textColor: SIMD4<Float>

        /// OCR boxes jitter a few pixels from read to read; re-laying out the text for that would
        /// re-rasterize every frame, so a sprite this close is kept.
        func canStandIn(for wanted: TextSpriteKey) -> Bool {
            text == wanted.text && textColor == wanted.textColor
                && abs(fontPixels - wanted.fontPixels) <= Self.fontTolerancePixels
                && abs(wrapPixels - wanted.wrapPixels) <= Self.wrapTolerancePixels
        }

        private static let fontTolerancePixels = 2
        private static let wrapTolerancePixels = 24
    }

    /// Text laid out by Core Text into a premultiplied BGRA texture, transparent around the glyphs.
    struct TextSprite {
        let key: TextSpriteKey
        let texture: MTLTexture
        let pixelSize: SIMD2<Float>
        /// The laid-out text itself: its widest line by its height, which the cover hugs.
        let textPixelSize: SIMD2<Float>

        private static let maximumSide = 4096

        init?(
            key: TextSpriteKey,
            device: MTLDevice
        ) {
            let framesetter = CTFramesetterCreateWithAttributedString(
                Self.attributedText(for: key, fontSize: CGFloat(key.fontPixels))
            )
            let wrapWidth = Self.balancedWidth(of: framesetter, within: CGFloat(key.wrapPixels))
            let fitted = Self.fittedSize(of: framesetter, width: wrapWidth)
            let width = Int(wrapWidth)
            let height = Int(fitted.height.rounded(.up))
            guard (1...Self.maximumSide).contains(width), (1...Self.maximumSide).contains(height),
                let context = Self.bitmapContext(width: width, height: height),
                let texture = Self.texture(width: width, height: height, device: device)
            else { return nil }

            let path = CGPath(rect: CGRect(x: 0, y: 0, width: wrapWidth, height: CGFloat(height)), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
            CTFrameDraw(frame, context)
            guard let pixels = context.data else { return nil }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: context.bytesPerRow
            )
            self.key = key
            self.texture = texture
            self.pixelSize = SIMD2(Float(width), Float(height))
            self.textPixelSize = SIMD2(min(Float(width), Self.widestLine(in: frame)), Float(height))
        }

        private static func widestLine(in frame: CTFrame) -> Float {
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            let widths = lines.map { line in
                CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
            }
            return Float(widths.max() ?? 0).rounded(.up)
        }

        /// The narrowest width that keeps the line count, so the lines come out even and the last
        /// one never holds a lone word; every overlay keeps its given font size.
        private static func balancedWidth(
            of framesetter: CTFramesetter,
            within wrapWidth: CGFloat
        ) -> CGFloat {
            let lines = lineCount(of: framesetter, width: wrapWidth)
            guard lines > 1 else { return wrapWidth }
            var fits = wrapWidth
            var tooNarrow = wrapWidth * minimumBalancedShare
            for _ in 0..<balanceSearchSteps {
                let middle = (fits + tooNarrow) / 2
                if lineCount(of: framesetter, width: middle) <= lines { fits = middle } else { tooNarrow = middle }
            }
            return fits.rounded(.up)
        }

        /// Even lines never need less than half the width; 6 halvings land within ~1% of it.
        private static let minimumBalancedShare: CGFloat = 0.5
        private static let balanceSearchSteps = 6

        private static func lineCount(
            of framesetter: CTFramesetter,
            width: CGFloat
        ) -> Int {
            let height = fittedSize(of: framesetter, width: width).height.rounded(.up)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: max(height, 1)), transform: nil)
            return CFArrayGetCount(CTFrameGetLines(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)))
        }

        private static func fittedSize(
            of framesetter: CTFramesetter,
            width: CGFloat
        ) -> CGSize {
            CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(),
                nil,
                CGSize(width: width, height: .greatestFiniteMagnitude),
                nil
            )
        }

        private static func attributedText(
            for key: TextSpriteKey,
            fontSize: CGFloat
        ) -> NSAttributedString {
            let color = CGColor(
                srgbRed: CGFloat(key.textColor.x),
                green: CGFloat(key.textColor.y),
                blue: CGFloat(key.textColor.z),
                alpha: CGFloat(key.textColor.w)
            )
            return NSAttributedString(
                string: key.text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ]
            )
        }

        /// Row 0 of a bitmap context's memory is the image's top, which is also a Metal texture's.
        private static func bitmapContext(
            width: Int,
            height: Int
        ) -> CGContext? {
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }

        private static func texture(
            width: Int,
            height: Int,
            device: MTLDevice
        ) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)
        }
    }
#endif
