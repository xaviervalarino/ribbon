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
wm.start()

// Keep daemon running on the main dispatch loop
dispatchMain()
