import Foundation

enum AppLogger {
    private static let lock = NSLock()

    static func info(_ message: String) {
        write("INFO", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try AppPaths.ensureDirectories()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: AppPaths.logFile.path) {
                let handle = try FileHandle(forWritingTo: AppPaths.logFile)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: AppPaths.logFile, options: .atomic)
            }
        } catch {
            // Logging must never break app behavior.
        }
    }
}
