import Foundation

public enum SocketServerError: Error {
    case alreadyRunning
    case pathTooLong
}

public final class SocketServer {
    public let socketPath: String
    private var serverSource: DispatchSourceRead?
    private var serverFD: Int32 = -1
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    public var onCommand: ((String) -> String)?

    private static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    public static func defaultPath() -> String {
        return "/tmp/ribbon-\(getuid()).sock"
    }

    private static func makeAddress(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            path.withCString { cstr in
                _ = strncpy(baseAddress.assumingMemoryBound(to: CChar.self), cstr, rawBuf.count - 1)
            }
        }
        return addr
    }

    public init(socketPath: String = SocketServer.defaultPath()) {
        self.socketPath = socketPath
    }

    public func start() throws {
        // strncpy won't null-terminate a path that fills sun_path
        guard socketPath.utf8.count < Self.maxPathBytes else {
            throw SocketServerError.pathTooLong
        }

        // Probe for a live daemon before unlinking, retrying briefly if an exiting instance is closing
        var isAlive = false
        for attempt in 0..<10 {
            let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
            if probeFD >= 0 {
                var probeAddr = Self.makeAddress(socketPath)
                let connectResult = withUnsafePointer(to: &probeAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(probeFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                close(probeFD)
                if connectResult == 0 {
                    isAlive = true
                    if attempt < 9 {
                        usleep(100_000) // 100ms backoff in case old process is in mid-exit
                        continue
                    }
                } else {
                    isAlive = false
                    break
                }
            }
        }
        if isAlive {
            throw SocketServerError.alreadyRunning
        }

        unlink(socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        var on: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(serverFD, F_SETFD, FD_CLOEXEC)

        var addr = Self.makeAddress(socketPath)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverFD)
            serverFD = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        chmod(socketPath, 0o600)

        guard listen(serverFD, 128) == 0 else {
            close(serverFD)
            serverFD = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        let fd = serverFD
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.serverSource = source
    }

    public func stop() {
        guard serverSource != nil else { return }

        for (_, source) in clientSources {
            source.cancel()
        }
        clientSources.removeAll()

        serverSource?.cancel()
        serverSource = nil
        serverFD = -1
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

        guard clientFD >= 0 else {
            // On fd exhaustion the pending connection is never drained and the
            // level-triggered source re-fires forever; back off briefly.
            if (errno == EMFILE || errno == ENFILE), let source = serverSource {
                source.suspend()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    source.resume()
                }
            }
            return
        }

        var on: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .main)
        clientSources[clientFD] = clientSource

        clientSource.setEventHandler { [weak self, weak clientSource] in
            var buffer = [CChar](repeating: 0, count: 1024)
            let bytesRead = read(clientFD, &buffer, buffer.count - 1)
            if bytesRead > 0 {
                let command = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                let started = DispatchTime.now()
                let response = (self?.onCommand?(command) ?? "ok") + "\n"
                AXEventObserver.logIfSlow("command '\(command)'", pid: getpid(), since: started)
                // A reply larger than the socket buffer takes several writes.
                let bytes = Array(response.utf8)
                var sent = 0
                while sent < bytes.count {
                    let n = bytes[sent...].withUnsafeBufferPointer { write(clientFD, $0.baseAddress, $0.count) }
                    guard n > 0 else { break }
                    sent += n
                }
            }
            clientSource?.cancel()
        }

        // Idle-client eviction. Capture the source, not the fd — fd numbers are
        // recycled, so a lookup by fd here could cancel a newer client's
        // connection. Cancelled from the source's cancel handler on the normal
        // path so completed connections don't leave timers on the queue.
        let eviction = DispatchWorkItem { [weak clientSource] in
            clientSource?.cancel()
        }
        clientSource.setCancelHandler { [weak self] in
            eviction.cancel()
            close(clientFD)
            self?.clientSources.removeValue(forKey: clientFD)
        }

        clientSource.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: eviction)
    }
}

