#if os(iOS)
    import Metal
    import MetalPerformanceShaders

    /// A small, heavily blurred copy of the camera frame that text covers sample as frosted glass,
    /// so the printed text under a translation dissolves instead of being painted over. Main thread only.
    @MainActor
    final class TextBackdrop {
        private let device: MTLDevice
        private let downscale: MPSImageBilinearScale
        private let blur: MPSImageGaussianBlur
        private var reduced: MTLTexture?
        private var blurred: MTLTexture?

        /// Blurring a quarter-size frame costs ~1/16 of a full one, and the blur hides the loss.
        private static let reduction = 4
        /// In reduced texels: ~20 full-resolution texels, enough to dissolve body-text strokes.
        private static let blurSigma: Float = 5

        init?(device: MTLDevice) {
            guard MPSSupportsMTLDevice(device) else { return nil }
            self.device = device
            self.downscale = MPSImageBilinearScale(device: device)
            self.blur = MPSImageGaussianBlur(device: device, sigma: Self.blurSigma)
            blur.edgeMode = .clamp
        }

        /// The blurred frame, encoded on `commandBuffer` ahead of the render pass that samples it.
        func encodeBlur(
            of camera: MTLTexture,
            in commandBuffer: MTLCommandBuffer
        ) -> MTLTexture? {
            let width = max(1, camera.width / Self.reduction)
            let height = max(1, camera.height / Self.reduction)
            guard let reduced = texture(reusing: reduced, width: width, height: height),
                let blurred = texture(reusing: blurred, width: width, height: height)
            else { return nil }
            self.reduced = reduced
            self.blurred = blurred
            downscale.encode(commandBuffer: commandBuffer, sourceTexture: camera, destinationTexture: reduced)
            blur.encode(commandBuffer: commandBuffer, sourceTexture: reduced, destinationTexture: blurred)
            return blurred
        }

        private func texture(
            reusing existing: MTLTexture?,
            width: Int,
            height: Int
        ) -> MTLTexture? {
            if let existing, existing.width == width, existing.height == height { return existing }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
    }
#endif
