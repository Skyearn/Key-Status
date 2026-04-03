import AppKit

final class PermissionWindowController: NSWindowController {
    private let retryHandler: () -> Void
    private let localizedAppName = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "键态" : "KeyStatus"

    init(retryHandler: @escaping () -> Void) {
        self.retryHandler = retryHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = localizedAppName
        window.contentViewController = PermissionViewController(retryHandler: retryHandler)

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeIfNeeded() {
        window?.close()
    }
}

private final class PermissionViewController: NSViewController {
    private let retryHandler: () -> Void

    init(retryHandler: @escaping () -> Void) {
        self.retryHandler = retryHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(wrappingLabelWithString: "键态 需要辅助功能权限")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        let descriptionLabel = NSTextField(
            wrappingLabelWithString: "请在“系统设置 > 隐私与安全性 > 辅助功能”中允许 键态。授权后，应用会在任意程序里第一次进入文本输入状态时，显示当前输入法和 Caps Lock 状态。"
        )
        descriptionLabel.font = .systemFont(ofSize: 14)
        descriptionLabel.textColor = .secondaryLabelColor

        let openSettingsButton = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        openSettingsButton.bezelStyle = .rounded

        let retryButton = NSButton(title: "我已授权，重新检测", target: self, action: #selector(retry))
        retryButton.bezelStyle = .rounded

        let stack = NSStackView(views: [titleLabel, descriptionLabel, openSettingsButton, retryButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])

        view = root
    }

    @objc private func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func retry() {
        retryHandler()
    }
}
