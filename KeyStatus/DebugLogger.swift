import Foundation

enum DebugLogger {
    private static let logURL: URL = {
        let fileManager = FileManager.default
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let logsDirectoryURL = libraryURL.appendingPathComponent("Logs/KeyStatus", isDirectory: true)
        try? fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        return logsDirectoryURL.appendingPathComponent("key-status.log", isDirectory: false)
    }()

    static func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: logURL.path) == false {
            FileManager.default.createFile(atPath: logURL.path, contents: data)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    @discardableResult
    static func measure<T>(_ label: String, _ block: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = block()
        let durationMs = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        log("\(label) durationMs=\(durationMs)")
        return result
    }

    static var logPath: String {
        logURL.path
    }
}
