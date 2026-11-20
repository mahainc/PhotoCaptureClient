#if os(iOS)
    import CoreGraphics
    import ImageIO
    import Metal
    import os

    /// A captured photo decoded upright into a texture the preview draws in place of the camera.
    enum StillTexture {
        /// Shown only, never read back, so it is capped near the drawable size.
        private static let maximumSide = 2048
        /// One byte per BGRA channel, matching `.bgra8Unorm`.
        private static let bitsPerChannel = 8
        private static let log = Logger(subsystem: "PhotoCaptureClient", category: "StillTexture")

        /// Drawn into the camera's own layout, BGRA in sRGB: a loader keeping the photo's channel
        /// order and Display P3 values showed the page tinted blue.
        static func make(
            from photoData: Data,
            device: MTLDevice
        ) -> MTLTexture? {
            guard let image = uprightImage(from: photoData),
                let context = bitmapContext(width: image.width, height: image.height)
            else {
                log.error("still photo could not be decoded")
                return nil
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return device.makeBGRATexture(copying: context)
        }

        /// The thumbnail applies the EXIF orientation, so the pixels match the rotated camera feed.
        private static func uprightImage(from photoData: Data) -> CGImage? {
            guard let source = CGImageSourceCreateWithData(photoData as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSide,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
                bitsPerComponent: bitsPerChannel,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
    }
#endif
