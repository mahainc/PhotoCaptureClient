#if os(iOS)
    import CoreGraphics
    import Metal

    extension MTLDevice {
        /// A BGRA texture holding a copy of `context`'s pixels: text sprites and captured stills.
        /// `context` must be 8-bit BGRA (`byteOrder32Little`, alpha or skip first).
        func makeBGRATexture(copying context: CGContext) -> MTLTexture? {
            guard let pixels = context.data else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: context.width,
                height: context.height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = makeTexture(descriptor: descriptor) else { return nil }
            texture.replace(
                region: MTLRegionMake2D(0, 0, context.width, context.height),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: context.bytesPerRow
            )
            return texture
        }
    }
#endif
