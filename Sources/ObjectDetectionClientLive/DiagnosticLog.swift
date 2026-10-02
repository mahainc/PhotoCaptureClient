import Foundation

/// Appends timestamped diagnostic lines to `Documents/yolo-diag.log` inside the app container, so a
/// device session can be pulled back with `devicectl device copy` and inspected — plain `print` does
/// not survive a `devicectl` launch. Thread-safe; a no-op if the container has no Documents directory.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    private let lock = NSLock()
    private let fileURL: URL?
    private let formatter: ISO8601DateFormatter

    private init() {
        fileURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("yolo-diag.log")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func log(_ message: String) {
        // Logging is a debug-only concern: a shipped build does no printing and no file I/O, so this
        // whole body compiles out of release. The on-device file lets a `devicectl`-launched debug
        // session be pulled back and inspected, where plain `print` does not survive.
        #if DEBUG
        print("[YOLO] \(message)")
        guard let fileURL else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
        #endif
    }
}
