import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else {
    print("""
    ribbon - native scrollable window manager CLI

    Usage:
      ribbon focus <left|right|up|down>
      ribbon swap <left|right|up|down>
      ribbon cycle-width (alias: cycle)
      ribbon slurp
      ribbon barf
      ribbon retile
      ribbon rescan
      ribbon status
    """)
    exit(0)
}

let command = arguments.joined(separator: " ")
let socketPath: String = {
    return "/tmp/ribbon-\(getuid()).sock"
}()

guard socketPath.utf8.count < 104 else {
    fputs("error: socket path too long: \(socketPath)\n", stderr)
    exit(1)
}

let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard clientFD >= 0 else {
    fputs("error: failed to create socket\n", stderr)
    exit(1)
}

var on: Int32 = 1
setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
    socketPath.withCString { cstr in
        strncpy(ptr, cstr, 104)
    }
}

let connectResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

guard connectResult == 0 else {
    fputs("error: ribbon-daemon is not running (cannot connect to \(socketPath))\n", stderr)
    close(clientFD)
    exit(1)
}

let payload = command + "\n"
payload.withCString { cstr in
    _ = write(clientFD, cstr, strlen(cstr))
}

var tv = timeval(tv_sec: 2, tv_usec: 0)
setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

var buffer = [CChar](repeating: 0, count: 1024)
let bytesRead = read(clientFD, &buffer, buffer.count - 1)
close(clientFD)

if bytesRead <= 0 {
    fputs("error: timed out waiting for daemon response\n", stderr)
    exit(1)
}

buffer[bytesRead] = 0
let response = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
if response.hasPrefix("error") {
    fputs("\(response)\n", stderr)
    exit(1)
}

if response != "ok" {
    print(response)
}
exit(0)

