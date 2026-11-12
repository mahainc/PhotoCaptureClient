#if os(iOS)
    @preconcurrency import MetalKit
    import simd

    extension MetalPreviewRenderer {

        // MARK: - Channel-Gain Filter

        /// Returns the texture the preview and histogram should read: the camera texture passed
        /// through the channel-gain filter. Neutral gain (or a missing pipeline) is a no-op that
        /// returns the camera texture unchanged, so the filter costs nothing when it is off.
        func filteredTexture(
            from camera: MTLTexture,
            gains: SIMD4<Float>,
            in commandBuffer: MTLCommandBuffer
        ) -> MTLTexture {
            guard gains != .one, let channelGainPipeline,
                let destination = gainDestination(matching: camera),
                let encoder = commandBuffer.makeComputeCommandEncoder()
            else {
                return camera
            }
            var gain = gains
            encoder.setComputePipelineState(channelGainPipeline)
            encoder.setTexture(camera, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setBytes(&gain, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            let tile = 16
            encoder.dispatchThreadgroups(
                MTLSize(
                    width: (camera.width + tile - 1) / tile,
                    height: (camera.height + tile - 1) / tile,
                    depth: 1
                ),
                threadsPerThreadgroup: MTLSize(width: tile, height: tile, depth: 1)
            )
            encoder.endEncoding()
            return destination
        }

        /// The filter's destination texture, (re)allocated to match the camera texture's size.
        private func gainDestination(matching camera: MTLTexture) -> MTLTexture? {
            if let existing = gainTexture, existing.width == camera.width, existing.height == camera.height {
                return existing
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: camera.width,
                height: camera.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            gainTexture = device.makeTexture(descriptor: descriptor)
            return gainTexture
        }
    }
#endif
