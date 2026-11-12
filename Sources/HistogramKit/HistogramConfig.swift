import Foundation

// MARK: - HistogramChannels

/// Which channels the overlay draws. R/G/B blend additively; luminance is the weighted
/// brightness curve photographers read for exposure.
public struct HistogramChannels: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let red = HistogramChannels(rawValue: 1 << 0)
    public static let green = HistogramChannels(rawValue: 1 << 1)
    public static let blue = HistogramChannels(rawValue: 1 << 2)
    public static let luminance = HistogramChannels(rawValue: 1 << 3)

    public static let rgb: HistogramChannels = [.red, .green, .blue]
    public static let all: HistogramChannels = [.red, .green, .blue, .luminance]
}

// MARK: - HistogramFrame

/// Where the overlay draws, as a normalized rect in the preview (top-left origin, 0...1).
public struct HistogramFrame: Sendable, Equatable {
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

    /// A wide strip across the lower preview, clear of the center subject.
    public static let bottom = HistogramFrame(x: 0.04, y: 0.72, width: 0.92, height: 0.22)
}

// MARK: - HistogramConfig

/// Appearance and sampling of the live histogram overlay. Defaults suit a handheld
/// viewfinder; a consumer overrides only what it needs.
public struct HistogramConfig: Sendable, Equatable {
    /// Channels to draw.
    public var channels: HistogramChannels
    /// Where the overlay sits in the preview.
    public var frame: HistogramFrame
    /// Opacity of each channel's fill (additive), 0...1.
    public var barOpacity: Float
    /// Opacity of the dark backing panel, 0...1. Zero hides the panel.
    public var panelOpacity: Float
    /// Read every Nth pixel on each axis when accumulating. Higher is cheaper, coarser.
    public var sampleStride: Int

    public init(
        channels: HistogramChannels = .all,
        frame: HistogramFrame = .bottom,
        barOpacity: Float = 0.85,
        panelOpacity: Float = 0.35,
        sampleStride: Int = 2
    ) {
        self.channels = channels
        self.frame = frame
        self.barOpacity = barOpacity
        self.panelOpacity = panelOpacity
        self.sampleStride = sampleStride
    }

    public static let `default` = HistogramConfig()
}
