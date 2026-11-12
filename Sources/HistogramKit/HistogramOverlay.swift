#if os(iOS)
    import Metal
    import simd

    // MARK: - GPU Parameter Structs (must match Histogram.metal exactly)

    /// Mirrors `AccumulateParams` in Histogram.metal.
    private struct AccumulateParams {
        var sampleStride: UInt32
        var width: UInt32
        var height: UInt32
    }

    /// Mirrors `QuadParams` in Histogram.metal.
    private struct QuadParams {
        var frame: SIMD4<Float>
        var color: SIMD4<Float>
    }

    /// Mirrors `BarsParams` in Histogram.metal.
    private struct BarsParams {
        var frame: SIMD4<Float>
        var color: SIMD4<Float>
        var channel: UInt32
        var binCount: UInt32
        var pad0: Float
        var pad1: Float
    }

    /// One channel's slot in the bins buffer and the colour it draws with.
    private struct ChannelDraw {
        let index: UInt32
        let color: SIMD3<Float>
    }

    /// The two things that differ between the panel and bars render pipelines: their shader
    /// pair and how the source blends onto what is already there.
    private struct RenderPipelineSpec {
        let vertexFunction: String
        let fragmentFunction: String
        let destinationBlend: MTLBlendFactor
    }

    /// The GPU objects the overlay owns, grouped so the factory hands them to `init` as one value.
    private struct Resources {
        let accumulatePipeline: MTLComputePipelineState
        let reduceMaxPipeline: MTLComputePipelineState
        let panelPipeline: MTLRenderPipelineState
        let barsPipeline: MTLRenderPipelineState
        let binsBuffer: MTLBuffer
        let maxBuffer: MTLBuffer
    }

    // MARK: - HistogramOverlay

    /// Computes a four-channel (R/G/B/Luma) histogram of a Metal texture and draws it back
    /// into a render pass — entirely on the GPU, with no readback on the live path. One
    /// instance is reusable across single-camera and multi-camera previews: both own an
    /// `MTLTexture` per frame and a `.bgra8Unorm` drawable.
    public final class HistogramOverlay {

        // MARK: Constants

        private static let binCount = 256
        private static let accumulateTileSize = 16
        private static let reduceGroupSize = 256
        /// A screen-space quad is a 4-corner triangle strip.
        private static let quadVertexCount = 4

        /// One row per channel: the toggle that enables it and the colour it draws with.
        /// Row order is the bins layout (R, G, B, Luma) and the channel index into the buffer.
        private static let channels: [(option: HistogramChannels, color: SIMD3<Float>)] = [
            (.red, SIMD3<Float>(1.0, 0.2, 0.2)),
            (.green, SIMD3<Float>(0.2, 1.0, 0.2)),
            (.blue, SIMD3<Float>(0.3, 0.5, 1.0)),
            (.luminance, SIMD3<Float>(1.0, 1.0, 1.0)),
        ]
        private static let channelCount = channels.count

        // MARK: Metal State

        private let accumulatePipeline: MTLComputePipelineState
        private let reduceMaxPipeline: MTLComputePipelineState
        private let panelPipeline: MTLRenderPipelineState
        private let barsPipeline: MTLRenderPipelineState

        /// Channel-major bin counts (`binCount * channelCount` uints), written by compute
        /// and read by the bars vertex shader. Stays resident on the GPU.
        private let binsBuffer: MTLBuffer
        /// Single global max bin count, used to scale bars to fill their frame.
        private let maxBuffer: MTLBuffer

        // MARK: Init

        /// The panel darkens what is behind it (alpha blend); the channel fills add onto it
        /// (additive) so overlapping R/G/B read as blended colour.
        private static let panelSpec = RenderPipelineSpec(
            vertexFunction: "histogramPanelVertex",
            fragmentFunction: "histogramPanelFragment",
            destinationBlend: .oneMinusSourceAlpha
        )
        private static let barsSpec = RenderPipelineSpec(
            vertexFunction: "histogramBarsVertex",
            fragmentFunction: "histogramBarsFragment",
            destinationBlend: .one
        )

        /// Builds the pipelines and buffers, or returns nil if Metal shader loading fails.
        public static func create(device: MTLDevice) -> HistogramOverlay? {
            guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
                let accumulatePipeline = makeComputePipeline(device, library, "histogramAccumulate"),
                let reduceMaxPipeline = makeComputePipeline(device, library, "histogramReduceMax"),
                let panelPipeline = makeRenderPipeline(device, library, panelSpec),
                let barsPipeline = makeRenderPipeline(device, library, barsSpec)
            else {
                return nil
            }

            let binsLength = binCount * channelCount * MemoryLayout<UInt32>.stride
            guard let binsBuffer = device.makeBuffer(length: binsLength, options: .storageModePrivate),
                let maxBuffer = device.makeBuffer(
                    length: MemoryLayout<UInt32>.stride,
                    options: .storageModePrivate
                )
            else {
                return nil
            }

            return HistogramOverlay(
                resources: Resources(
                    accumulatePipeline: accumulatePipeline,
                    reduceMaxPipeline: reduceMaxPipeline,
                    panelPipeline: panelPipeline,
                    barsPipeline: barsPipeline,
                    binsBuffer: binsBuffer,
                    maxBuffer: maxBuffer
                )
            )
        }

        private init(resources: Resources) {
            self.accumulatePipeline = resources.accumulatePipeline
            self.reduceMaxPipeline = resources.reduceMaxPipeline
            self.panelPipeline = resources.panelPipeline
            self.barsPipeline = resources.barsPipeline
            self.binsBuffer = resources.binsBuffer
            self.maxBuffer = resources.maxBuffer
        }

        // MARK: Compute

        /// Recomputes the histogram of `texture` into the resident buffers. Encodes a clear,
        /// an accumulate pass and a max reduction onto `commandBuffer` — call it before the
        /// render encoder that `encodeDraw` writes into, so the draw reads fresh bins.
        public func encodeCompute(
            texture: MTLTexture,
            in commandBuffer: MTLCommandBuffer,
            config: HistogramConfig
        ) {
            clearBuffers(in: commandBuffer)
            encodeAccumulate(texture: texture, in: commandBuffer, config: config)
            encodeReduceMax(in: commandBuffer)
        }

        private func clearBuffers(in commandBuffer: MTLCommandBuffer) {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
            blit.fill(buffer: binsBuffer, range: 0..<binsBuffer.length, value: 0)
            blit.fill(buffer: maxBuffer, range: 0..<maxBuffer.length, value: 0)
            blit.endEncoding()
        }

        private func encodeAccumulate(
            texture: MTLTexture,
            in commandBuffer: MTLCommandBuffer,
            config: HistogramConfig
        ) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            let stride = UInt32(max(config.sampleStride, 1))
            var params = AccumulateParams(
                sampleStride: stride,
                width: UInt32(texture.width),
                height: UInt32(texture.height)
            )
            encoder.setComputePipelineState(accumulatePipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(binsBuffer, offset: 0, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<AccumulateParams>.stride, index: 1)

            let tile = Self.accumulateTileSize
            let sampledWidth = Self.ceilDiv(texture.width, Int(stride))
            let sampledHeight = Self.ceilDiv(texture.height, Int(stride))
            let threadgroups = MTLSize(
                width: Self.ceilDiv(sampledWidth, tile),
                height: Self.ceilDiv(sampledHeight, tile),
                depth: 1
            )
            encoder.dispatchThreadgroups(
                threadgroups,
                threadsPerThreadgroup: MTLSize(width: tile, height: tile, depth: 1)
            )
            encoder.endEncoding()
        }

        private func encodeReduceMax(in commandBuffer: MTLCommandBuffer) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            var binTotal = UInt32(Self.binCount * Self.channelCount)
            encoder.setComputePipelineState(reduceMaxPipeline)
            encoder.setBuffer(binsBuffer, offset: 0, index: 0)
            encoder.setBuffer(maxBuffer, offset: 0, index: 1)
            encoder.setBytes(&binTotal, length: MemoryLayout<UInt32>.stride, index: 2)

            let total = Self.binCount * Self.channelCount
            let group = Self.reduceGroupSize
            encoder.dispatchThreadgroups(
                MTLSize(width: Self.ceilDiv(total, group), height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: group, height: 1, depth: 1)
            )
            encoder.endEncoding()
        }

        /// Threadgroup count that covers `count` items in groups of `size` (round up).
        private static func ceilDiv(
            _ count: Int,
            _ size: Int
        ) -> Int {
            (count + size - 1) / size
        }

        // MARK: Draw

        /// Draws the backing panel and the enabled channels into an open render pass. Reads
        /// the bins from the last `encodeCompute`; safe to call every frame while compute is
        /// throttled, since the buffers persist between recomputes.
        public func encodeDraw(
            in encoder: MTLRenderCommandEncoder,
            config: HistogramConfig
        ) {
            drawPanel(in: encoder, config: config)
            drawChannels(in: encoder, config: config)
        }

        private func drawPanel(
            in encoder: MTLRenderCommandEncoder,
            config: HistogramConfig
        ) {
            guard config.panelOpacity > 0 else { return }
            var params = QuadParams(
                frame: config.frame.simd,
                color: SIMD4<Float>(0, 0, 0, config.panelOpacity)
            )
            encoder.setRenderPipelineState(panelPipeline)
            encoder.setVertexBytes(&params, length: MemoryLayout<QuadParams>.stride, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<QuadParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Self.quadVertexCount)
        }

        private func drawChannels(
            in encoder: MTLRenderCommandEncoder,
            config: HistogramConfig
        ) {
            let channels = Self.enabledChannels(config.channels)
            guard !channels.isEmpty else { return }
            encoder.setRenderPipelineState(barsPipeline)
            encoder.setVertexBuffer(binsBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(maxBuffer, offset: 0, index: 1)

            let verticesPerChannel = Self.binCount * 2
            for channel in channels {
                var params = BarsParams(
                    frame: config.frame.simd,
                    color: SIMD4<Float>(channel.color, config.barOpacity),
                    channel: channel.index,
                    binCount: UInt32(Self.binCount),
                    pad0: 0,
                    pad1: 0
                )
                encoder.setVertexBytes(&params, length: MemoryLayout<BarsParams>.stride, index: 2)
                encoder.drawPrimitives(
                    type: .triangleStrip,
                    vertexStart: 0,
                    vertexCount: verticesPerChannel
                )
            }
        }

        // MARK: Readback (tests / offline only)

        /// Runs a compute pass on `texture` synchronously and reads the bins back. Not for
        /// the live path — it blocks on GPU completion.
        public func readback(
            texture: MTLTexture,
            config: HistogramConfig,
            commandQueue: MTLCommandQueue
        ) -> HistogramBins? {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
            guard let readableBins = makeReadableBins(commandQueue: commandQueue) else { return nil }
            encodeCompute(texture: texture, in: commandBuffer, config: config)
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            blit.copy(
                from: binsBuffer,
                sourceOffset: 0,
                to: readableBins,
                destinationOffset: 0,
                size: binsBuffer.length
            )
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return Self.decodeBins(readableBins)
        }

        private func makeReadableBins(commandQueue: MTLCommandQueue) -> MTLBuffer? {
            commandQueue.device.makeBuffer(length: binsBuffer.length, options: .storageModeShared)
        }

        private static func decodeBins(_ buffer: MTLBuffer) -> HistogramBins {
            let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: binCount * channelCount)
            func slice(_ channel: Int) -> [UInt32] {
                Array(UnsafeBufferPointer(start: pointer + channel * binCount, count: binCount))
            }
            return HistogramBins(red: slice(0), green: slice(1), blue: slice(2), luminance: slice(3))
        }

        // MARK: Channel Selection

        private static func enabledChannels(_ enabled: HistogramChannels) -> [ChannelDraw] {
            channels.enumerated().compactMap { index, row in
                guard enabled.contains(row.option) else { return nil }
                return ChannelDraw(index: UInt32(index), color: row.color)
            }
        }

        // MARK: Pipeline Builders

        private static func makeComputePipeline(
            _ device: MTLDevice,
            _ library: MTLLibrary,
            _ functionName: String
        ) -> MTLComputePipelineState? {
            guard let function = library.makeFunction(name: functionName) else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }

        private static func makeRenderPipeline(
            _ device: MTLDevice,
            _ library: MTLLibrary,
            _ spec: RenderPipelineSpec
        ) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: spec.vertexFunction)
            descriptor.fragmentFunction = library.makeFunction(name: spec.fragmentFunction)
            guard let attachment = descriptor.colorAttachments[0] else { return nil }
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = spec.destinationBlend
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
    }

    // MARK: - HistogramFrame → GPU

    extension HistogramFrame {
        fileprivate var simd: SIMD4<Float> {
            SIMD4<Float>(x, y, width, height)
        }
    }
#endif
