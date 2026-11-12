import CasePaths
import CoreGraphics
import CoreVideo
import Foundation
import PhotoCaptureClient

#if os(iOS)
    import UIKit
#endif

// MARK: - Aspect Ratio

extension MultiCamClient {
    public enum AspectRatio: String, Sendable, Equatable, Codable, CaseIterable {
        case ratio9x16 = "9:16"
        case ratio16x9 = "16:9"
        case ratio1x1 = "1:1"
        case ratio4x3 = "4:3"

        public var label: String { rawValue }

        /// Output size for a given base resolution (short edge).
        public func outputSize(baseWidth: Int) -> (width: Int, height: Int) {
            switch self {
                case .ratio9x16: return (baseWidth, baseWidth * 16 / 9)
                case .ratio16x9: return (baseWidth * 16 / 9, baseWidth)
                case .ratio1x1: return (baseWidth, baseWidth)
                case .ratio4x3: return (baseWidth, baseWidth * 4 / 3)
            }
        }
    }
}

// MARK: - Layout Preset

extension MultiCamClient {
    public enum LayoutPreset: String, Sendable, Equatable, CaseIterable, Codable {
        case equal
        case stacked
        case focusFirst
        case focusLast
        case pip

        public var icon: String {
            switch self {
                case .equal: "rectangle.3.group"
                case .stacked: "rectangle.grid.1x3"
                case .focusFirst: "rectangle.leadinghalf.inset.filled"
                case .focusLast: "rectangle.trailinghalf.inset.filled"
                case .pip: "pip"
            }
        }

        public var label: String {
            switch self {
                case .equal: "Equal"
                case .stacked: "Stacked"
                case .focusFirst: "Focus Left"
                case .focusLast: "Focus Right"
                case .pip: "PiP"
            }
        }
    }
}

// MARK: - Layout

extension MultiCamClient {
    /// How cameras are composited for preview and recording.
    public enum Layout: Sendable, Equatable {
        case grid(GridLayout)
        case pip(PiPLayout)
        case custom(CustomLayout)
    }

    public struct GridLayout: Sendable, Equatable {
        /// Number of columns. 1 = vertical stack, 2 = side-by-side or 2x2.
        public var columns: Int

        public init(columns: Int = 2) {
            self.columns = max(1, columns)
        }
    }

    public struct PiPLayout: Sendable, Equatable {
        public var primary: CameraID
        public var overlay: CameraID
        public var overlayPosition: PiPPosition
        /// Fraction of primary view size (0.0-1.0).
        public var overlayScale: CGFloat

        public init(
            primary: CameraID = .backWide,
            overlay: CameraID = .frontWide,
            overlayPosition: PiPPosition = .bottomTrailing,
            overlayScale: CGFloat = 0.25
        ) {
            self.primary = primary
            self.overlay = overlay
            self.overlayPosition = overlayPosition
            self.overlayScale = min(max(overlayScale, 0.1), 0.5)
        }
    }

    public enum PiPPosition: Sendable, Equatable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
        /// Custom normalized position (0-1 space, origin = top-left).
        case custom(x: CGFloat, y: CGFloat)
    }

    public struct CustomLayout: Sendable, Equatable {
        /// Per-camera normalized frame (origin + size in 0-1 space).
        public var frames: [CameraID: CGRect]
        /// Per-camera corner radius (0 = sharp, 0.5 = circular).
        public var cornerRadii: [CameraID: CGFloat]

        public init(
            frames: [CameraID: CGRect],
            cornerRadii: [CameraID: CGFloat] = [:]
        ) {
            self.frames = frames
            self.cornerRadii = cornerRadii
        }
    }
}

// MARK: - PreviewView

extension MultiCamClient {
    /// A Sendable wrapper around a UIView (Metal-backed multi-camera preview).
    public final class PreviewView: @unchecked Sendable, Equatable {
        #if os(iOS)
            public let view: UIView
        #endif

        /// Current layout applied to the preview.
        public var layout: Layout

        #if os(iOS)
            public init(
                view: UIView,
                layout: Layout = .grid(.init())
            ) {
                self.view = view
                self.layout = layout
            }
        #endif

        public static func == (
            lhs: PreviewView,
            rhs: PreviewView
        ) -> Bool {
            lhs.view === rhs.view
        }
    }
}
