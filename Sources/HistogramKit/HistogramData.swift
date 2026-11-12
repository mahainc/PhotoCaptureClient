import Foundation

extension Histogram {

    /// A snapshot of the four per-channel bin counts, read back from the GPU. Used for tests
    /// and offline inspection — the live overlay never reads this back on its hot path.
    public struct Bins: Sendable, Equatable {
        public var red: [UInt32]
        public var green: [UInt32]
        public var blue: [UInt32]
        public var luminance: [UInt32]

        public init(
            red: [UInt32],
            green: [UInt32],
            blue: [UInt32],
            luminance: [UInt32]
        ) {
            self.red = red
            self.green = green
            self.blue = blue
            self.luminance = luminance
        }
    }
}
