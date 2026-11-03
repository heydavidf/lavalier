import AppKit

/// Three rows with live status. Re-checks whenever the window becomes key and every two seconds while open.
@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    private var rows: [(Permission, NSTextField, NSButton)] = []
    private var timer: Timer?
    private let summary = NSTextField(wrappingLabelWithString: "")
    /// Fired on every status refresh (the rows re-check every two seconds). Must not record a dismissal.
    var onChange: (() -> Void)?
    /// Fired once when the user closes the window. This is the only place a dismissal is recorded.
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lavalier Permissions"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])

        let intro = NSTextField(wrappingLabelWithString:
            "Lavalier needs these macOS permissions. Click Request to get the system prompt, or Open System Settings to switch it on there. Rows update by themselves once granted.")
        intro.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(intro)

        for permission in Permission.allCases {
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 4
            let title = NSTextField(labelWithString: permission.title + (permission.required ? "" : " (only if needed)"))
            title.font = .boldSystemFont(ofSize: 13)
            let why = NSTextField(wrappingLabelWithString: permission.why)
            why.preferredMaxLayoutWidth = 520
            why.textColor = .secondaryLabelColor
            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = 10
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 12, weight: .medium)
            let request = NSButton(title: "Request", target: self, action: #selector(requestTapped(_:)))
            request.tag = Permission.allCases.firstIndex(of: permission)!
            let open = NSButton(title: "Open System Settings", target: self, action: #selector(openTapped(_:)))
            open.tag = request.tag
            line.addArrangedSubview(status)
            line.addArrangedSubview(request)
            line.addArrangedSubview(open)
            box.addArrangedSubview(title)
            box.addArrangedSubview(why)
            box.addArrangedSubview(line)
            stack.addArrangedSubview(box)
            rows.append((permission, status, request))
        }

        summary.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(summary)
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.keyEquivalent = "\r"
        stack.addArrangedSubview(done)
        refresh()
    }

    func refresh() {
        for (permission, label, button) in rows {
            let status = permission.status
            label.stringValue = status.label
            label.textColor = status == .granted ? .systemGreen : (permission.required ? .systemRed : .secondaryLabelColor)
            button.isEnabled = status != .granted
        }
        let missing = Permission.missingRequired
        summary.stringValue = missing.isEmpty
            ? "All required permissions are granted."
            : "Still needed: " + missing.map(\.title).joined(separator: ", ") + "."
        onChange?()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @objc private func requestTapped(_ sender: NSButton) {
        let permission = Permission.allCases[sender.tag]
        permission.request { [weak self] in Task { @MainActor in self?.refresh() } }
    }

    @objc private func openTapped(_ sender: NSButton) {
        Permission.allCases[sender.tag].openSettings()
    }

    @objc private func doneTapped() { window?.close() }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }

    var isShowing: Bool { window?.isVisible ?? false }
}
