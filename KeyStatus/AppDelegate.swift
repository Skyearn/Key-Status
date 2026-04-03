import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let inputSourceService = InputSourceService()
    private lazy var statusItemController = StatusItemController(inputSourceService: inputSourceService)
    private lazy var overlayController = OverlayWindowController(
        onPresentedStatusChanged: { [weak self] status in
            self?.statusItemController.setPresentedStatus(status)
        }
    )
    private lazy var focusMonitor = FocusMonitor(
        inputSourceService: inputSourceService,
        onStatusDetected: { [weak self] status, anchorRect in
            self?.overlayController.show(status: status, anchorRect: anchorRect)
        }
    )

    override init() {
        DebugLogger.log("AppDelegate.init")
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        statusItemController.refresh(force: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLogger.clear()
        let launchStart = CFAbsoluteTimeGetCurrent()
        DebugLogger.log("applicationDidFinishLaunching start")
        DebugLogger.log("debug log path=\(DebugLogger.logPath)")
        DebugLogger.measure("setActivationPolicy.accessory") {
            NSApp.setActivationPolicy(.accessory)
        }
        DebugLogger.measure("statusItemController.start") {
            statusItemController.start()
        }
        DispatchQueue.main.async { [weak self] in
            self?.requestPermissionsAndStart()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.statusItemController.refresh(force: true)
        }
        let durationMs = Int(((CFAbsoluteTimeGetCurrent() - launchStart) * 1000).rounded())
        DebugLogger.log("applicationDidFinishLaunching scheduled durationMs=\(durationMs)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        focusMonitor.stop()
        statusItemController.stop()
    }

    private func requestPermissionsAndStart() {
        let trusted = DebugLogger.measure("AXIsProcessTrusted.initial") { AXIsProcessTrusted() }
        DebugLogger.log("requestPermissionsAndStart trusted=\(trusted)")

        if trusted {
            focusMonitor.start()
            return
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let promptedTrusted = DebugLogger.measure("AXIsProcessTrustedWithOptions") {
            AXIsProcessTrustedWithOptions(options)
        }

        let postPromptTrusted = DebugLogger.measure("AXIsProcessTrusted.afterPrompt") { AXIsProcessTrusted() }
        DebugLogger.log("requestPermissionsAndStart promptResult=\(promptedTrusted) trustedAfterPrompt=\(postPromptTrusted)")

        if postPromptTrusted {
            focusMonitor.start()
        } else {
            DebugLogger.log("accessibility not trusted, awaiting user authorization")
            focusMonitor.start()
        }
    }
}
