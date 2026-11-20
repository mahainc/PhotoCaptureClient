#if os(iOS)
    import Metal
    import PhotoCaptureClient
    import QuartzCore
    import simd

    /// The renderer's mapping of the current frame, which text quads are placed and rasterized by.
    struct TextOverlayGeometry {
        /// Camera texture size in texels.
        let textureSize: SIMD2<Float>
        /// Drawable pixels one texel covers on screen, visual zoom included.
        let pixelsPerTexel: Float
        let contentScale: Float
        let uniforms: AspectFillUniforms
    }

    /// Draws `TextOverlay`s inside the camera pass, so text moves in step with the frame under it
    /// and eases toward each new position instead of jumping. Main thread only.
    @MainActor
    final class TextOverlayLayer {
        private struct ShownText {
            let id: UUID
            /// x, y, width, height, normalized to the texture.
            var frame: SIMD4<Float>
            var angle: Float
            var opacity: Float
            var sprite: TextSprite
            var background: SIMD4<Float>

            func withOpacity(_ opacity: Float) -> ShownText {
                var faded = self
                faded.opacity = opacity
                return faded
            }
        }

        private let device: MTLDevice
        private let pipeline: MTLRenderPipelineState
        private var wanted: [PhotoCaptureClient.TextOverlay] = []
        private var shown: [UUID: ShownText] = [:]
        private var lastEncodeTime: CFTimeInterval?
        private var rasterizedThisFrame = 0
        /// Where the last frame drew each cover, normalized to the texture, for tap hit-testing.
        private var drawnCovers: [(id: UUID, frame: CGRect)] = []
        /// The last placement, reused while no cover moved, faded or changed its text.
        private var placement: Placement?

        /// Seconds for a cover to close ~63% of the gap to its new position.
        private static let followTimeConstant: Float = 0.07
        private static let fadeSeconds: Float = 0.25
        /// A cover this far from its target (normalized) jumps there instead of sliding across.
        private static let snapDistance: Float = 0.2
        /// A cover this close to its target (normalized, well under a pixel) lands on it and stops.
        private static let settleDistance: Float = 0.0005
        /// A stalled frame must not fling covers across the screen when drawing resumes.
        private static let longestStep: CFTimeInterval = 0.1
        /// Core Text work per frame is capped so a page of new translations never stalls a draw.
        private static let rasterizationsPerFrame = 8
        /// The cover reaches this far past the source box, so no original glyph edge peeks out.
        private static let coverOutsetPoints: Float = 2
        private static let cornerRadiusPoints: Float = 3
        /// A font's cap-to-descender span is ~1.2× its point size, so this fills a printed line.
        private static let pointsPerLineHeight: Float = 0.92
        private static let unitQuad: [SIMD2<Float>] = [[0, 0], [1, 0], [0, 1], [1, 0], [1, 1], [0, 1]]

        init(
            device: MTLDevice,
            pipeline: MTLRenderPipelineState
        ) {
            self.device = device
            self.pipeline = pipeline
        }

        func update(_ overlays: [PhotoCaptureClient.TextOverlay]) {
            wanted = overlays
        }

        /// The cover under `texturePoint` (normalized), topmost first; rotation is ignored.
        func overlayID(at texturePoint: SIMD2<Float>) -> UUID? {
            guard hasContent else { return nil }
            let point = CGPoint(x: CGFloat(texturePoint.x), y: CGFloat(texturePoint.y))
            return drawnCovers.last { $0.frame.contains(point) }?.id
        }

        /// Whether a draw would put anything on screen, so the backdrop blur is worth encoding.
        var hasContent: Bool { !wanted.isEmpty || !shown.isEmpty }

        /// `backdrop` is the blurred camera frame the covers show through.
        func encode(
            in encoder: MTLRenderCommandEncoder,
            geometry: TextOverlayGeometry,
            backdrop: MTLTexture
        ) {
            let step = advanceClock()
            guard hasContent, geometry.pixelsPerTexel > 0 else { return }
            rasterizedThisFrame = 0
            follow(geometry: geometry, step: step)
            fadeOutLeftOverlays(step: step)
            draw(in: encoder, geometry: geometry, backdrop: backdrop)
        }

        private func advanceClock() -> Float {
            let now = CACurrentMediaTime()
            defer { lastEncodeTime = now }
            guard let lastEncodeTime else { return 0 }
            return Float(min(now - lastEncodeTime, Self.longestStep))
        }

        private func follow(
            geometry: TextOverlayGeometry,
            step: Float
        ) {
            for overlay in wanted {
                let key = Self.spriteKey(for: overlay, geometry: geometry)
                let current = shown[overlay.id]
                guard let sprite = Self.reusable(current?.sprite, for: key) ?? rasterize(key) else { continue }
                let target = SIMD4(
                    Float(overlay.frame.minX),
                    Float(overlay.frame.minY),
                    Float(overlay.frame.width),
                    Float(overlay.frame.height)
                )
                shown[overlay.id] = ShownText(
                    id: overlay.id,
                    frame: current.map { Self.eased($0.frame, toward: target, step: step) } ?? target,
                    angle: Float(overlay.angle),
                    opacity: current.map { min(1, $0.opacity + step / Self.fadeSeconds) } ?? 0,
                    sprite: sprite,
                    background: overlay.backgroundColor
                )
            }
        }

        private func fadeOutLeftOverlays(step: Float) {
            let wantedIDs = Set(wanted.map(\.id))
            for (id, item) in shown where !wantedIDs.contains(id) {
                let opacity = item.opacity - step / Self.fadeSeconds
                shown[id] = opacity > 0 ? item.withOpacity(opacity) : nil
            }
        }

        private func rasterize(_ key: TextSpriteKey) -> TextSprite? {
            guard rasterizedThisFrame < Self.rasterizationsPerFrame else { return nil }
            rasterizedThisFrame += 1
            return TextSprite(key: key, device: device)
        }

        private static func reusable(
            _ sprite: TextSprite?,
            for key: TextSpriteKey
        ) -> TextSprite? {
            guard let sprite, sprite.key.canStandIn(for: key) else { return nil }
            return sprite
        }

        private static func spriteKey(
            for overlay: PhotoCaptureClient.TextOverlay,
            geometry: TextOverlayGeometry
        ) -> TextSpriteKey {
            let lineTexels = Float(overlay.lineHeight) * geometry.textureSize.y
            let widthTexels = Float(overlay.frame.width) * geometry.textureSize.x
            return TextSpriteKey(
                text: overlay.text,
                fontPixels: max(1, Int((lineTexels * pointsPerLineHeight * geometry.pixelsPerTexel).rounded())),
                wrapPixels: max(1, Int((widthTexels * geometry.pixelsPerTexel).rounded())),
                textColor: overlay.textColor
            )
        }

        private static func eased(
            _ frame: SIMD4<Float>,
            toward target: SIMD4<Float>,
            step: Float
        ) -> SIMD4<Float> {
            let distance = simd_distance(frame, target)
            guard distance < snapDistance, distance > settleDistance else { return target }
            return frame + (target - frame) * (1 - exp(-step / followTimeConstant))
        }

        private func draw(
            in encoder: MTLRenderCommandEncoder,
            geometry: TextOverlayGeometry,
            backdrop: MTLTexture
        ) {
            guard let placement = currentPlacement(geometry: geometry), let buffer = placement.vertices else { return }
            let covers = placement.covers
            var uniforms = geometry.uniforms
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<AspectFillUniforms>.size, index: 1)
            encoder.setFragmentTexture(backdrop, index: 1)
            for (index, cover) in covers.enumerated() {
                encoder.setFragmentTexture(cover.item.sprite.texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: index * Self.unitQuad.count,
                    vertexCount: Self.unitQuad.count
                )
            }
        }

        /// Placing covers is quadratic in their count, so it reruns only when its inputs change.
        private func currentPlacement(geometry: TextOverlayGeometry) -> Placement? {
            let key = Placement.Key(shown: shown, geometry: geometry)
            if let placement, placement.key == key {
                return placement
            }
            let covers = Self.placedCovers(Array(shown.values), geometry: geometry)
            drawnCovers = covers.map { ($0.item.id, $0.normalizedFrame(in: geometry.textureSize)) }
            let vertices = covers.flatMap { Self.vertices(for: $0, geometry: geometry) }
            let buffer =
                vertices.isEmpty
                ? nil
                : device.makeBuffer(
                    bytes: vertices,
                    length: vertices.count * MemoryLayout<TextVertex>.stride,
                    options: .storageModeShared
                )
            placement = Placement(key: key, covers: covers, vertices: buffer)
            return placement
        }

        private struct Placement {
            struct Key: Equatable {
                struct Text: Equatable {
                    let frame: SIMD4<Float>
                    let angle: Float
                    let opacity: Float
                    let sprite: ObjectIdentifier
                    let background: SIMD4<Float>
                }

                let geometry: SIMD4<Float>
                let texts: [UUID: Text]

                init(
                    shown: [UUID: ShownText],
                    geometry: TextOverlayGeometry
                ) {
                    self.geometry = SIMD4(
                        geometry.textureSize.x,
                        geometry.textureSize.y,
                        geometry.pixelsPerTexel,
                        geometry.contentScale
                    )
                    texts = shown.mapValues { text in
                        Text(
                            frame: text.frame,
                            angle: text.angle,
                            opacity: text.opacity,
                            sprite: ObjectIdentifier(text.sprite.texture),
                            background: text.background
                        )
                    }
                }
            }

            let key: Key
            let covers: [PlacedCover]
            let vertices: MTLBuffer?
        }

        /// A cover's place this frame, in texels: it hugs its text and starts at the source box.
        private struct PlacedCover {
            let item: ShownText
            var origin: SIMD2<Float>
            let size: SIMD2<Float>

            var maxY: Float { origin.y + size.y }

            func normalizedFrame(in textureSize: SIMD2<Float>) -> CGRect {
                let origin = origin / textureSize
                let size = size / textureSize
                return CGRect(
                    x: CGFloat(origin.x),
                    y: CGFloat(origin.y),
                    width: CGFloat(size.x),
                    height: CGFloat(size.y)
                )
            }

            func overlaps(_ other: PlacedCover) -> Bool {
                origin.x < other.origin.x + other.size.x && other.origin.x < origin.x + size.x
                    && origin.y < other.maxY && other.origin.y < maxY
            }
        }

        /// Exact placement yields to legibility: top to bottom, a cover that would
        /// overlap one already placed moves below it, so no two covers ever overlap.
        private static func placedCovers(
            _ items: [ShownText],
            geometry: TextOverlayGeometry
        ) -> [PlacedCover] {
            let outset = coverOutsetPoints * geometry.contentScale / geometry.pixelsPerTexel
            let covers = items.map { item in
                PlacedCover(
                    item: item,
                    origin: SIMD2(item.frame.x, item.frame.y) * geometry.textureSize - outset,
                    size: item.sprite.textPixelSize / geometry.pixelsPerTexel + 2 * outset
                )
            }
            .sorted { ($0.origin.y, $0.origin.x) < ($1.origin.y, $1.origin.x) }
            var placed: [PlacedCover] = []
            for var cover in covers {
                // Each move lands below a cover placed earlier, so this ends within `placed.count` moves.
                while let blocker = placed.first(where: cover.overlaps) {
                    cover.origin.y = blocker.maxY
                }
                placed.append(cover)
            }
            return placed
        }

        /// One quad over the cover, rotated about its top-left like the printed line.
        private static func vertices(
            for cover: PlacedCover,
            geometry: TextOverlayGeometry
        ) -> [TextVertex] {
            let pixelsPerTexel = geometry.pixelsPerTexel
            let outset = coverOutsetPoints * geometry.contentScale / pixelsPerTexel
            let spriteTexels = cover.item.sprite.pixelSize / pixelsPerTexel
            let halfPixels = cover.size * pixelsPerTexel * 0.5
            let cornerRadius = min(cornerRadiusPoints * geometry.contentScale, halfPixels.min())
            let angle = cover.item.angle
            let rotation = float2x2(SIMD2(cos(angle), sin(angle)), SIMD2(-sin(angle), cos(angle)))
            return unitQuad.map { corner in
                let local = corner * cover.size
                return TextVertex(
                    background: cover.item.background,
                    position: (cover.origin + rotation * local) / geometry.textureSize,
                    localPos: local * pixelsPerTexel - halfPixels,
                    halfSize: halfPixels,
                    spriteUV: (local - outset) / spriteTexels,
                    params: SIMD2(cornerRadius, cover.item.opacity)
                )
            }
        }
    }
#endif
