// MARK: - Detection

/// A single raw detection fed into the tracker: a normalized box plus its class label and an optional
/// metric depth sampled at the box centre. Identity-less by design — the tracker assigns the stable
/// `Track.id`.
public struct Detection: Sendable, Equatable {
    public var box: TrackBox
    public var confidence: Float
    public var label: String
    /// Metric depth in metres at the box centre (smaller = nearer). `nil` on non-depth devices — the
    /// tracker just carries it through (EMA-smoothed) for the consumer's nearest-object ranking.
    public var depth: Float?

    public init(
        box: TrackBox,
        confidence: Float,
        label: String,
        depth: Float? = nil
    ) {
        self.box = box
        self.confidence = confidence
        self.label = label
        self.depth = depth
    }
}
