#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    import PhotoCaptureClient
    import simd

    extension MetalPreviewRenderer {

        // MARK: - Overlay Drawing

        /// Writes one quad per box into the vertex buffer; the rounded, anti-aliased border
        /// (thickness + corner radius) is computed per-pixel in the fragment shader.
        func drawOverlays(
            _ overlays: [PhotoCaptureClient.OverlayRect],
            encoder: MTLRenderCommandEncoder
        ) {
            encoder.setRenderPipelineState(boxPipeline)

            // One quad (2 triangles = 6 vertices) per box.
            let verticesPerBox = 6
            let maxBoxes = Self.maxBoxVertices / verticesPerBox

            let pointer = boxVertexBuffer.contents().bindMemory(
                to: BoxVertex.self,
                capacity: Self.maxBoxVertices
            )

            let transform = currentOverlayTransform()

            let scale = Float(mtkView.contentScaleFactor)
            let drawableWidth = Float(mtkView.drawableSize.width)
            let drawableHeight = Float(mtkView.drawableSize.height)
            guard drawableWidth > 0, drawableHeight > 0 else { return }
            let borderPixels = Float(boxBorderWidth) * scale
            // One pixel of padding so the anti-aliased outer edge isn't clipped by the quad.
            let padPixels: Float = 1

            var idx = 0
            for index in 0..<min(overlays.count, maxBoxes) {
                let overlay = overlays[index]
                // Map texture space → screen-normalized (aspect-fill + zoom). Returns nil when the box
                // is not fully inside the visible preview, so partially-cropped boxes are skipped.
                guard let rect = visibleScreenRect(for: overlay, transform: transform) else {
                    continue
                }

                // Box geometry in pixels.
                let halfWidthPixels = rect.width * drawableWidth * 0.5
                let halfHeightPixels = rect.height * drawableHeight * 0.5
                let radiusPixels = min(Float(boxCornerRadius) * scale, min(halfWidthPixels, halfHeightPixels))

                // Box center in Metal clip space (-1..1, bottom-left origin).
                let centerX = (rect.minX + rect.width * 0.5) * 2.0 - 1.0
                let centerY = 1.0 - (rect.minY + rect.height * 0.5) * 2.0

                // Quad half-extent (box + AA padding) in clip space and matching local pixel coords.
                let halfClipX = (halfWidthPixels + padPixels) / drawableWidth * 2.0
                let halfClipY = (halfHeightPixels + padPixels) / drawableHeight * 2.0
                let localX = halfWidthPixels + padPixels
                let localY = halfHeightPixels + padPixels

                let color = overlay.color
                let halfSize = SIMD2<Float>(halfWidthPixels, halfHeightPixels)
                let params = SIMD2<Float>(radiusPixels, borderPixels)

                func addVertex(
                    _ clipX: Float,
                    _ clipY: Float,
                    _ localPosX: Float,
                    _ localPosY: Float
                ) {
                    pointer[idx] = BoxVertex(
                        color: color,
                        position: SIMD2<Float>(clipX, clipY),
                        localPos: SIMD2<Float>(localPosX, localPosY),
                        halfSize: halfSize,
                        params: params
                    )
                    idx += 1
                }

                // Two triangles covering the padded box quad.
                addVertex(centerX - halfClipX, centerY - halfClipY, -localX, -localY)
                addVertex(centerX + halfClipX, centerY - halfClipY, localX, -localY)
                addVertex(centerX - halfClipX, centerY + halfClipY, -localX, localY)
                addVertex(centerX + halfClipX, centerY - halfClipY, localX, -localY)
                addVertex(centerX + halfClipX, centerY + halfClipY, localX, localY)
                addVertex(centerX - halfClipX, centerY + halfClipY, -localX, localY)
            }

            guard idx > 0 else { return }

            encoder.setVertexBuffer(boxVertexBuffer, offset: 0, index: 0)
            // Draw only the vertices actually written — boxes outside the visible frame are skipped.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: idx)
        }
    }
#endif
