import AppKit

@MainActor
final class StatusItemController {
    private static let inputSourceChangedNotification = Notification.Name("com.apple.HIToolbox.selectedKeyboardInputSourceChanged")

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusIconSize = NSSize(width: 18, height: 18)
    private lazy var lightMenuBarCapsOffImage = makeMenuBarStatusIcon(capsLockOn: false, darkBackground: false)
    private lazy var lightMenuBarCapsOnImage = makeMenuBarStatusIcon(capsLockOn: true, darkBackground: false)
    private lazy var darkMenuBarCapsOffImage = makeMenuBarStatusIcon(capsLockOn: false, darkBackground: true)
    private lazy var darkMenuBarCapsOnImage = makeMenuBarStatusIcon(capsLockOn: true, darkBackground: true)

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var refreshTimer: Timer?
    private var inputSourceObserver: NSObjectProtocol?
    private var lastCapsLockState: Bool?
    private var lastStatusSignature: String?
    private let localizedAppName = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "键态" : "KeyStatus"

    init(inputSourceService: InputSourceService) {
        _ = inputSourceService
    }

    func refresh(force: Bool) {
        updateIcon(force: force)
    }

    func setPresentedStatus(_ status: InputStatus?) {
        _ = status
    }

    func start() {
        DebugLogger.log("StatusItemController.start")
        configureMenu()
        refresh(force: true)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateIcon(force: false)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateIcon(force: false)
            }
            return event
        }

        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.inputSourceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateIcon(force: false)
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.80, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateIcon(force: false)
            }
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: localizedAppName, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.toolTip = localizedAppName
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.font = .systemFont(ofSize: 12, weight: .bold)
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.image = resolvedStatusItemImage(capsLockOn: currentCapsLockOn)
        DebugLogger.log("status item configured buttonExists=\(statusItem.button != nil)")
    }

    private func updateIcon(force: Bool) {
        let capsLockOn = currentCapsLockOn
        let darkBackground = isUsingDarkMenuBarBackground
        let statusSignature = makeStatusSignature(capsLockOn: capsLockOn, darkBackground: darkBackground)
        guard force || lastCapsLockState != capsLockOn || lastStatusSignature != statusSignature else { return }
        lastCapsLockState = capsLockOn
        lastStatusSignature = statusSignature

        let image = resolvedStatusItemImage(capsLockOn: capsLockOn)
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.image = image
        statusItem.button?.title = ""
        updateApplicationIcon(capsLockOn: capsLockOn)
        DebugLogger.log("status item update source=minimal-menu-icon imageLoaded=\(image != nil) capsLockOn=\(capsLockOn) darkBackground=\(darkBackground)")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func loadImage(named name: String) -> NSImage? {
        if let image = NSImage(named: name) {
            return image
        }

        if
            let directURL = Bundle.main.resourceURL?.appendingPathComponent("Resources/\(name).png"),
            let image = NSImage(contentsOf: directURL)
        {
            return image
        }

        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources") else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    private func updateApplicationIcon(capsLockOn: Bool) {
        let iconName = capsLockOn ? "app-icon-caps-on" : "app-icon-caps-off"
        guard let image = loadImage(named: iconName) else { return }
        NSApp.applicationIconImage = image
    }

    private var currentCapsLockOn: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }

    private var isUsingDarkMenuBarBackground: Bool {
        statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func makeStatusSignature(capsLockOn: Bool, darkBackground: Bool) -> String {
        "minimal-icon|\(capsLockOn)|\(darkBackground)"
    }

    private func resolvedStatusItemImage(capsLockOn: Bool) -> NSImage? {
        if isUsingDarkMenuBarBackground {
            return capsLockOn ? darkMenuBarCapsOnImage : darkMenuBarCapsOffImage
        }

        return capsLockOn ? lightMenuBarCapsOnImage : lightMenuBarCapsOffImage
    }

    private func makeMenuBarStatusIcon(capsLockOn: Bool, darkBackground: Bool) -> NSImage? {
        let image = NSImage(size: statusIconSize)
        image.lockFocus()

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: statusIconSize)).fill()

        let fillColor = darkBackground
            ? NSColor.white
            : NSColor.black
        let shapeRect = NSRect(x: 1.0, y: 1.0, width: 16.0, height: 16.0)
        let shapePath = NSBezierPath(roundedRect: shapeRect, xRadius: 4.8, yRadius: 4.8)
        fillColor.setFill()
        shapePath.fill()

        let dotRect = NSRect(x: 3.9, y: 11.1, width: 3.9, height: 3.9)
        if capsLockOn {
            NSColor(srgbRed: 51.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0, alpha: 1).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        } else {
            let dotPath = NSBezierPath(ovalIn: dotRect)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            dotPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        image.unlockFocus()
        image.size = statusIconSize
        image.isTemplate = false
        return image
    }
}
