import Foundation

public enum RibbonLog {
    private static let queue = DispatchQueue(label: "com.ribbon.logger", qos: .utility)
    public static let logFilePath = "/tmp/ribbon.log"
    private static let maxLogBytes: UInt64 = 5 * 1024 * 1024 // 5 MB auto-rotation

    private static let dateFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    public static func log(
        _ message: @autoclosure () -> String,
        category: String = "daemon",
        file: String = #fileID,
        line: Int = #line
    ) {
        let msg = message()
        let timestamp = dateFormatter.string(from: Date())
        let shortFile = (file as NSString).lastPathComponent
        let lineStr = "[\(timestamp)] [\(category)] (\(shortFile):\(line)) \(msg)\n"

        queue.async {
            guard let data = lineStr.data(using: .utf8) else { return }
            let fm = FileManager.default
            if fm.fileExists(atPath: logFilePath) {
                if let attrs = try? fm.attributesOfItem(atPath: logFilePath),
                   let size = attrs[.size] as? UInt64,
                   size > maxLogBytes {
                    try? fm.removeItem(atPath: logFilePath + ".old")
                    try? fm.moveItem(atPath: logFilePath, toPath: logFilePath + ".old")
                    fm.createFile(atPath: logFilePath, contents: data)
                    return
                }
                if let handle = FileHandle(forWritingAtPath: logFilePath) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                fm.createFile(atPath: logFilePath, contents: data)
            }
        }
    }
}
