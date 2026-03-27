import AppKit

@MainActor
final class OverlayWindowController: NSWindowController {
    private let statusView = StatusView()
    private let onPresentedStatusChanged: (InputStatus?) -> Void
    private var dismissWorkItem: DispatchWorkItem?

    init(onPresentedStatusChanged: @escaping (InputStatus?) -> Void = { _ in }) {
        self.onPresentedStatusChanged = onPresentedStatusChanged
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        panel.contentView = statusView

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(status: InputStatus, anchorRect: CGRect?) {
        statusView.update(status: status)
        onPresentedStatusChanged(status)
        positionWindow(anchorRect: anchorRect)

        guard let window else { return }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }

        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    private func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: { [weak window] in
            Task { @MainActor in
                self.onPresentedStatusChanged(nil)
                window?.orderOut(nil)
            }
        })
    }

    private func positionWindow(anchorRect: CGRect?) {
        guard let window else { return }

        let fallbackLocation = NSEvent.mouseLocation
        let targetRect = anchorRect ?? CGRect(origin: fallbackLocation, size: .zero)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(targetRect.origin) || $0.frame.intersects(targetRect.insetBy(dx: -20, dy: -20)) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let preferredX = targetRect.minX + 8
        let preferredY = targetRect.minY - window.frame.height - 8

        let x = min(max(preferredX, visibleFrame.minX + 8), visibleFrame.maxX - window.frame.width - 8)
        let y: CGFloat
        if preferredY < visibleFrame.minY + 8 {
            y = min(targetRect.maxY + 8, visibleFrame.maxY - window.frame.height - 8)
        } else {
            y = preferredY
        }

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class StatusView: NSView {
    private let backgroundView = NSView()
    private let capsDotView = NSView()
    private let inputSourceIconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.96).cgColor
        backgroundView.layer?.cornerRadius = 12
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.layer?.borderWidth = 0.5
        backgroundView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        capsDotView.wantsLayer = true
        capsDotView.layer?.cornerRadius = 3
        capsDotView.translatesAutoresizingMaskIntoConstraints = false

        inputSourceIconView.imageScaling = .scaleProportionallyUpOrDown
        inputSourceIconView.translatesAutoresizingMaskIntoConstraints = false
        inputSourceIconView.contentTintColor = NSColor.white.withAlphaComponent(0.95)
        addSubview(backgroundView)
        backgroundView.addSubview(capsDotView)
        backgroundView.addSubview(inputSourceIconView)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            capsDotView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 6),
            capsDotView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 6),
            capsDotView.widthAnchor.constraint(equalToConstant: 6),
            capsDotView.heightAnchor.constraint(equalToConstant: 6),

            inputSourceIconView.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
            inputSourceIconView.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor, constant: 1),
            inputSourceIconView.widthAnchor.constraint(equalToConstant: 24),
            inputSourceIconView.heightAnchor.constraint(equalToConstant: 20)
        ])

        alphaValue = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(status: InputStatus) {
        if let icon = status.inputSourceIcon {
            inputSourceIconView.image = icon
            inputSourceIconView.isHidden = false
        } else {
            inputSourceIconView.image = nil
            inputSourceIconView.isHidden = true
        }
        capsDotView.layer?.backgroundColor = (status.capsLockOn ? NSColor.systemGreen : NSColor.white).cgColor
    }
}
