import Foundation
import ApplicationServices
import AppKit

// Check Accessibility Permissions
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(options) else {
    print("""
    [ribbon-daemon] ERROR: Accessibility permissions required.
    Please grant Accessibility permissions to ribbon-daemon (or your terminal)
    in System Settings -> Privacy & Security -> Accessibility.
    """)
    exit(1)
}

print("[ribbon-daemon] Starting native Ribbon Window Manager daemon...")
let wm = WindowManager()

let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        print("[ribbon-daemon] Shutting down...")
        wm.stop()
        exit(0)
    }
    source.resume()
    return source
}

do {
    try wm.start()
} catch SocketServerError.alreadyRunning {
    fputs("[ribbon-daemon] error: another ribbon-daemon is already running\n", stderr)
    exit(1)
} catch SocketServerError.pathTooLong {
    fputs("[ribbon-daemon] error: socket path too long\n", stderr)
    exit(1)
} catch {
    fputs("[ribbon-daemon] error: failed to start socket server: \(error)\n", stderr)
    exit(1)
}

// Keep daemon running on the main run loop
RunLoop.main.run()
