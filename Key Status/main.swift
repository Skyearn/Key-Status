import AppKit

DebugLogger.clear()
DebugLogger.log("main.swift starting")

let app = NSApplication.shared
DebugLogger.log("NSApplication.shared created")
let delegate = MainActor.assumeIsolated { AppDelegate() }
DebugLogger.log("AppDelegate created")
app.delegate = delegate
DebugLogger.log("delegate assigned")
app.run()
DebugLogger.log("app.run returned")
