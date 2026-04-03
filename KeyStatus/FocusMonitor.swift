import AppKit
import ApplicationServices

@MainActor
final class FocusMonitor {
    private static let inputSourceChangedNotification = Notification.Name("com.apple.HIToolbox.selectedKeyboardInputSourceChanged")

    private let inputSourceService: InputSourceService
    private let onStatusDetected: (InputStatus, CGRect?) -> Void

    private var observers: [pid_t: AXObserver] = [:]
    private var focusedTextSignature: String?
    private var focusedElement: AXUIElement?
    private var lastKnownCaretRect: CGRect?
    private var lastPresentationAnchorRect: CGRect?
    private var permissionTimer: Timer?
    private var focusPollingTimer: Timer?
    private var globalEventMonitors: [Any] = []
    private var statusChangeMonitors: [Any] = []
    private var inputSourceObserver: NSObjectProtocol?
    private var lastStatusSignature: String?
    private var statusRecheckWorkItem: DispatchWorkItem?
    private var focusRetryWorkItem: DispatchWorkItem?
    private var lastFocusFetchFailureFingerprint: String?
    private var lastQQRejectedFocusSignature: String?
    private var lastAnchorOutOfScreenSignature: String?

    init(inputSourceService: InputSourceService, onStatusDetected: @escaping (InputStatus, CGRect?) -> Void) {
        self.inputSourceService = inputSourceService
        self.onStatusDetected = onStatusDetected
    }

    func start() {
        let trusted = DebugLogger.measure("FocusMonitor.AXIsProcessTrusted") { AXIsProcessTrusted() }
        DebugLogger.log("FocusMonitor.start trusted=\(trusted)")
        guard trusted else {
            schedulePermissionRetry()
            return
        }

        permissionTimer?.invalidate()
        focusPollingTimer?.invalidate()
        DebugLogger.measure("FocusMonitor.registerForWorkspaceNotifications") {
            registerForWorkspaceNotifications()
        }
        DebugLogger.measure("FocusMonitor.installGlobalFocusFallbacks") {
            installGlobalFocusFallbacks()
        }
        DebugLogger.measure("FocusMonitor.installFocusPolling") {
            installFocusPolling()
        }
        DebugLogger.measure("FocusMonitor.installStatusChangeFallbacks") {
            installStatusChangeFallbacks()
        }
        DispatchQueue.main.async { [weak self] in
            self?.performInitialWarmupPass()
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        focusPollingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        globalEventMonitors.forEach(NSEvent.removeMonitor)
        globalEventMonitors.removeAll()
        statusChangeMonitors.forEach(NSEvent.removeMonitor)
        statusChangeMonitors.removeAll()
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
        statusRecheckWorkItem?.cancel()
        statusRecheckWorkItem = nil
        focusRetryWorkItem?.cancel()
        focusRetryWorkItem = nil
        lastAnchorOutOfScreenSignature = nil

        for (pid, observer) in observers {
            AXObserverRemoveNotification(observer, AXUIElementCreateApplication(pid), kAXFocusedUIElementChangedNotification as CFString)
        }
        observers.removeAll()
    }

    private func schedulePermissionRetry() {
        guard permissionTimer == nil else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                Task { @MainActor in
                    self.permissionTimer = nil
                    self.start()
                }
            }
        }
    }

    private func registerForWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appDidLaunch(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidActivate(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func installGlobalFocusFallbacks() {
        guard globalEventMonitors.isEmpty else { return }

        let eventTypes: [NSEvent.EventTypeMask] = [.leftMouseUp, .keyDown]
        for eventType in eventTypes {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: eventType, handler: { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(60))
                    self?.evaluateCurrentFocus()
                }
            }) {
                globalEventMonitors.append(monitor)
            }
        }
    }

    private func installFocusPolling() {
        guard focusPollingTimer == nil else { return }

        focusPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.80, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateCurrentFocus()
            }
        }
    }

    private func installStatusChangeFallbacks() {
        guard statusChangeMonitors.isEmpty, inputSourceObserver == nil else { return }

        if let globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(forceMouseFallback: false, scheduleRecheck: true)
            }
        }) {
            statusChangeMonitors.append(globalFlagsMonitor)
        }

        if let localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(forceMouseFallback: false, scheduleRecheck: true)
            }
            return event
        }) {
            statusChangeMonitors.append(localFlagsMonitor)
        }

        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.inputSourceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(forceMouseFallback: false, scheduleRecheck: true)
            }
        }
    }

    private func performInitialWarmupPass() {
        DebugLogger.measure("FocusMonitor.registerObserver.frontmost") {
            registerObserverForFrontmostAppIfPossible()
        }
        DebugLogger.measure("FocusMonitor.evaluateCurrentFocus.initial") {
            evaluateCurrentFocus()
        }
        DebugLogger.measure("FocusMonitor.handleStatusChange.initial") {
            handleStatusChange(forceMouseFallback: false, scheduleRecheck: true)
        }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        registerObserverIfPossible(for: app)
    }

    @objc private func appDidActivate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            registerObserverIfPossible(for: app)
        } else {
            registerObserverForFrontmostAppIfPossible()
        }
        evaluateCurrentFocus()
    }

    private func registerObserverForFrontmostAppIfPossible() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        registerObserverIfPossible(for: frontmost)
    }

    private func registerObserverIfPossible(for app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, observerCallback, &observer)
        guard result == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let addResult = AXObserverAddNotification(
            observer,
            appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard addResult == .success else { return }

        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func evaluateCurrentFocus() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObject)

        guard result == .success, let focusedObject else {
            if shouldTreatFocusFetchFailureAsTransient(result) {
                let fingerprint = "\(result.rawValue)|\(frontmostApplicationIdentity)"
                if fingerprint != lastFocusFetchFailureFingerprint {
                    lastFocusFetchFailureFingerprint = fingerprint
                    DebugLogger.log("QQ focus fetch transient failure result=\(result.rawValue) app=\(frontmostApplicationIdentity)")
                }
                scheduleFocusRetry()

                if let focusedElement, isTextInput(focusedElement) {
                    return
                }
            }

            if isQQFrontmostApplication {
                let fingerprint = "\(result.rawValue)|\(frontmostApplicationIdentity)"
                if fingerprint != lastFocusFetchFailureFingerprint {
                    lastFocusFetchFailureFingerprint = fingerprint
                    DebugLogger.log("QQ focus fetch failed result=\(result.rawValue) app=\(frontmostApplicationIdentity)")
                }
            } else {
                lastFocusFetchFailureFingerprint = nil
            }
            focusedTextSignature = nil
            focusedElement = nil
            lastPresentationAnchorRect = nil
            return
        }

        focusRetryWorkItem?.cancel()
        focusRetryWorkItem = nil
        lastFocusFetchFailureFingerprint = nil
        let element = focusedObject as! AXUIElement
        handleFocusedElement(element)
    }

    private func handleFocusedElement(_ element: AXUIElement) {
        guard isTextInput(element) else {
            logQQRejectedFocusedElementIfNeeded(element)
            focusedTextSignature = nil
            focusedElement = nil
            lastPresentationAnchorRect = nil
            return
        }

        lastQQRejectedFocusSignature = nil
        let signature = signatureForElement(element)
        if focusedTextSignature == signature {
            return
        }

        focusedTextSignature = signature
        focusedElement = element
        let pointerAnchorRect = CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
        lastPresentationAnchorRect = pointerAnchorRect
        let anchorRect = definiteCaretRect(for: element)
        if let anchorRect {
            lastKnownCaretRect = anchorRect
        }
        DebugLogger.log("focused text element detected signature=\(signature) pointerAnchor=\(NSStringFromRect(pointerAnchorRect)) caretAnchor=\(anchorRect.map { NSStringFromRect($0) } ?? "nil")")
        onStatusDetected(inputSourceService.currentStatus(), pointerAnchorRect)
    }

    private func handleStatusChange(forceMouseFallback: Bool, scheduleRecheck: Bool) {
        let status = inputSourceService.currentStatus()
        let signature = "\(status.identitySignature)|caps=\(status.capsLockOn)"
        let hasChanged = signature != lastStatusSignature
        if hasChanged {
            lastStatusSignature = signature
        }

        let resolvedAnchorRect: CGRect?
        if forceMouseFallback {
            resolvedAnchorRect = nil
        } else if let focusedElement, isTextInput(focusedElement) {
            if let lastPresentationAnchorRect {
                resolvedAnchorRect = lastPresentationAnchorRect
            } else {
                let pointerAnchorRect = CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
                lastPresentationAnchorRect = pointerAnchorRect
                resolvedAnchorRect = pointerAnchorRect
            }
        } else if isQQFrontmostApplication, let lastPresentationAnchorRect {
            resolvedAnchorRect = lastPresentationAnchorRect
        } else {
            resolvedAnchorRect = nil
        }

        if hasChanged {
            DebugLogger.log("status changed signature=\(signature) anchor=\(resolvedAnchorRect.map { NSStringFromRect($0) } ?? "mouse")")
            onStatusDetected(status, resolvedAnchorRect)
        }

        guard scheduleRecheck else { return }
        statusRecheckWorkItem?.cancel()
        let recheckWorkItem = DispatchWorkItem { [weak self] in
            self?.handleStatusChange(forceMouseFallback: forceMouseFallback, scheduleRecheck: false)
        }
        statusRecheckWorkItem = recheckWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: recheckWorkItem)
    }

    private var frontmostApplicationIdentity: String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "name=nil|bundle=nil|pid=0"
        }

        return "name=\(app.localizedName ?? "nil")|bundle=\(app.bundleIdentifier ?? "nil")|pid=\(app.processIdentifier)"
    }

    private var isQQFrontmostApplication: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        let appName = app.localizedName?.lowercased() ?? ""

        return bundleID.contains("tencent.qq")
            || bundleID.contains("tencent.mobileqq")
            || bundleID.contains("qq")
            || appName == "qq"
            || appName.contains("qq")
    }

    private func logQQRejectedFocusedElementIfNeeded(_ element: AXUIElement) {
        guard isQQFrontmostApplication else { return }

        let role = attribute(kAXRoleAttribute, for: element) as? String ?? "nil-role"
        let subrole = attribute(kAXSubroleAttribute, for: element) as? String ?? "nil-subrole"
        let editable = (attribute("AXEditable", for: element) as? Bool).map(String.init) ?? "nil"
        let identifier = attribute("AXIdentifier", for: element) as? String ?? "nil-id"
        let title = attribute(kAXTitleAttribute, for: element) as? String ?? ""
        let description = attribute(kAXDescriptionAttribute, for: element) as? String ?? ""
        let valueClass = attribute(kAXValueAttribute, for: element).map { String(describing: type(of: $0)) } ?? "nil-value"

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let signature = [String(pid), role, subrole, editable, identifier, title, description, valueClass].joined(separator: "|")
        guard signature != lastQQRejectedFocusSignature else { return }
        lastQQRejectedFocusSignature = signature

        DebugLogger.log(
            "QQ focused element rejected as non-text app=\(frontmostApplicationIdentity) role=\(role) subrole=\(subrole) editable=\(editable) identifier=\(identifier) valueClass=\(valueClass) title=\(title) description=\(description)"
        )
    }

    private func shouldTreatFocusFetchFailureAsTransient(_ error: AXError) -> Bool {
        guard isQQFrontmostApplication else { return false }
        return error == .noValue || error == .cannotComplete
    }

    private func scheduleFocusRetry() {
        focusRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateCurrentFocus()
        }
        focusRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func isTextInput(_ element: AXUIElement) -> Bool {
        let role = attribute(kAXRoleAttribute, for: element) as? String
        let subrole = attribute(kAXSubroleAttribute, for: element) as? String
        let editable = attribute("AXEditable", for: element) as? Bool

        if editable == true { return true }

        switch role {
        case kAXTextFieldRole,
             kAXTextAreaRole,
             kAXComboBoxRole:
            return true
        default:
            return subrole == kAXSecureTextFieldSubrole || subrole == "AXSearchField"
        }
    }

    private func signatureForElement(_ element: AXUIElement) -> String {
        let role = attribute(kAXRoleAttribute, for: element) as? String ?? "unknown-role"
        let title = attribute(kAXTitleAttribute, for: element) as? String ?? ""
        let valueDescription = attribute(kAXDescriptionAttribute, for: element) as? String ?? ""
        let identifier = attribute("AXIdentifier", for: element) as? String ?? ""

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        return [String(pid), role, identifier, title, valueDescription].joined(separator: "|")
    }

    private func attribute(_ key: String, for element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value as AnyObject?
    }

    private func definiteCaretRect(for element: AXUIElement) -> CGRect? {
        if let caretRect = caretRect(for: element),
           isUsefulAnchorCandidate(caretRect),
           let normalizedCaretRect = normalizedAnchorRect(from: caretRect) {
            return normalizedCaretRect
        }

        if let fallbackCaretRect = adjacentCharacterCaretRect(for: element),
           isUsefulAnchorCandidate(fallbackCaretRect),
           let normalizedFallbackRect = normalizedAnchorRect(from: fallbackCaretRect) {
            DebugLogger.log("using adjacent-character caret fallback=\(NSStringFromRect(normalizedFallbackRect))")
            return normalizedFallbackRect
        }
        return nil
    }

    private func caretRect(for element: AXUIElement) -> CGRect? {
        guard let rangeValue = attribute(kAXSelectedTextRangeAttribute, for: element) else {
            return nil
        }

        return boundsForRangeValue(rangeValue, element: element)
    }

    private func boundsForRangeValue(_ rangeValue: AnyObject, element: AXUIElement) -> CGRect? {
        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )

        guard result == .success, let boundsValue else {
            return nil
        }

        return cgRect(from: boundsValue)
    }

    private func adjacentCharacterCaretRect(for element: AXUIElement) -> CGRect? {
        guard let rangeValue = attribute(kAXSelectedTextRangeAttribute, for: element),
              let selectedRange = cfRange(from: rangeValue) else {
            return nil
        }

        let fullText = (attribute(kAXValueAttribute, for: element) as? String) ?? ""
        let textCount = fullText.count
        guard textCount > 0 else { return nil }

        if selectedRange.location > 0 {
            let previousRange = CFRange(location: selectedRange.location - 1, length: 1)
            if let previousValue = axValue(for: previousRange),
               let previousRect = boundsForRangeValue(previousValue, element: element),
               isUsefulAnchorCandidate(previousRect) {
                return CGRect(x: previousRect.maxX, y: previousRect.minY, width: 1, height: max(previousRect.height, 16))
            }
        }

        if selectedRange.location < textCount {
            let nextRange = CFRange(location: selectedRange.location, length: 1)
            if let nextValue = axValue(for: nextRange),
               let nextRect = boundsForRangeValue(nextValue, element: element),
               isUsefulAnchorCandidate(nextRect) {
                return CGRect(x: nextRect.minX, y: nextRect.minY, width: 1, height: max(nextRect.height, 16))
            }
        }

        return nil
    }

    private func cgRect(from value: AnyObject) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }
        return rect
    }

    private func cfRange(from value: AnyObject) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func axValue(for range: CFRange) -> AXValue? {
        var mutableRange = range
        return AXValueCreate(.cfRange, &mutableRange)
    }

    private func cgPoint(from value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func cgSize(from value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func normalizedAnchorRect(from rect: CGRect) -> CGRect? {
        let convertedRect = convertAccessibilityRectToScreenCoordinates(rect)

        if intersectsAnyScreen(convertedRect) {
            lastAnchorOutOfScreenSignature = nil
            return convertedRect
        }

        if rect.height > 40, rect.width > 40, intersectsAnyScreen(rect) {
            lastAnchorOutOfScreenSignature = nil
            return rect
        }

        let signature = "\(NSStringFromRect(rect))|\(NSStringFromRect(convertedRect))"
        if signature != lastAnchorOutOfScreenSignature {
            lastAnchorOutOfScreenSignature = signature
            DebugLogger.log("anchor rect fell outside screens raw=\(NSStringFromRect(rect)) converted=\(NSStringFromRect(convertedRect))")
        }
        return nil
    }

    private func isUsefulAnchorCandidate(_ rect: CGRect) -> Bool {
        if rect.isNull || rect.isInfinite {
            return false
        }

        if rect.width <= 1, rect.height <= 1, rect.origin.x == 0, rect.origin.y == 0 {
            return false
        }

        return rect.width > 0 || rect.height > 0
    }

    private func convertAccessibilityRectToScreenCoordinates(_ rect: CGRect) -> CGRect {
        let desktopBounds = NSScreen.screens.map(\.frame).reduce(CGRect.null) { partialResult, frame in
            partialResult.union(frame)
        }

        guard !desktopBounds.isNull else {
            return rect
        }

        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func intersectsAnyScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(rect) || screen.frame.intersects(rect)
        }
    }
}

private let observerCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        monitor.evaluateCurrentFocus()
    }
}
