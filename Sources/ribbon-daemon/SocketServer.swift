import Foundation

public final class SocketServer {
    public let socketPath: String
    private var serverSource: DispatchSourceRead?
    private var serverFD: Int32 = -1
    public var onCommand: ((String) -> String)?

    public init(socketPath: String = "/tmp/ribbon.sock") {
        self.socketPath = socketPath
    }

    public func start() throws {
        unlink(socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { cstr in
                strncpy(ptr, cstr, 104)
                return strlen(cstr)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathLength + 1)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, addrLen)
            }
        }

        guard bindResult == 0 else {
            close(serverFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        guard listen(serverFD, 128) == 0 else {
            close(serverFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.resume()
        self.serverSource = source
    }

    public func stop() {
        serverSource?.cancel()
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFD, $0, &clientLen)
            }
        }

        guard clientFD >= 0 else { return }

        var buffer = [CChar](repeating: 0, count: 1024)
        let bytesRead = read(clientFD, &buffer, buffer.count - 1)
        if bytesRead > 0 {
            let command = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            let response = (onCommand?(command) ?? "ok") + "\n"
            response.withCString { cstr in
                _ = write(clientFD, cstr, strlen(cstr))
            }
        }
        close(clientFD)
    }
}
