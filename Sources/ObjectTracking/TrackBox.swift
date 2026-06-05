import simd

// MARK: - TrackBox

/// A normalized, top-left-origin bounding box in `0...1` coordinate space — the geometric unit the
/// tracker operates on. Deliberately decoupled from any detector type so this module has **no package
/// dependencies** (boxmot's own design: a tracker independent of the detector). The live layer maps its
/// own box type to/from this.
public struct TrackBox: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(
        x: Float,
        y: Float,
        width: Float,
        height: Float
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Centre point of the box.
    public var center: SIMD2<Float> {
        SIMD2(x + width * 0.5, y + height * 0.5)
    }

    /// Intersection-over-union of two boxes (`0` when disjoint).
    public static func iou(
        _ a: TrackBox,
        _ b: TrackBox
    ) -> Float {
        let interX1 = max(a.x, b.x)
        let interY1 = max(a.y, b.y)
        let interX2 = min(a.x + a.width, b.x + b.width)
        let interY2 = min(a.y + a.height, b.y + b.height)
        let interW = max(0, interX2 - interX1)
        let interH = max(0, interY2 - interY1)
        let intersection = interW * interH
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
