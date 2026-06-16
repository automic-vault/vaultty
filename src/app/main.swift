import AppKit
import AppUpdater

private enum AppWindowMetrics {
    static let defaultContentSize = NSSize(width: 1120, height: 760)
    static let minimumContentSize = NSSize(width: 760, height: 480)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    private struct StoredSSHHost: Codable {
        var id: String
        var alias: String
        var hostname: String
        var user: String
        var port: Int
        var remoteHelperPath: String
        var enrolled: Bool
    }

    private struct StoredSSHHosts: Codable {
        var hosts: [StoredSSHHost]
    }

    private let updater = AppUpdater(owner: "automic-vault", repo: "vaultty")
    private var window: NSWindow?
    private var controller: TerminalViewController?
    private var titleToolbar: NSToolbar?
    private var pendingDirectoryURLs: [URL] = []
    private var stagedUpdate: Update?
    private var updateCheckTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let args = ProcessInfo.processInfo.arguments
        let selfTestCommand = args.enumerated().first { $0.element == "--self-test" }
            .flatMap { index, _ in args.indices.contains(index + 1) ? args[index + 1] : nil }
        let controller = TerminalViewController(selfTestCommand: selfTestCommand)
        controller.loadViewIfNeeded()
        controller.onInstallStagedUpdate = { [weak self] in
            self?.confirmInstallStagedUpdate()
        }
        self.controller = controller

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AppWindowMetrics.defaultContentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Vaultty"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: .vaulttyTitlebar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        titleToolbar = toolbar
        window.minSize = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: AppWindowMetrics.minimumContentSize),
            styleMask: styleMask
        ).size
        window.contentMinSize = AppWindowMetrics.minimumContentSize
        window.setContentSize(AppWindowMetrics.defaultContentSize)
        window.center()
        if let nativeContentView = window.contentView {
            controller.view.frame = nativeContentView.bounds
            controller.view.autoresizingMask = [.width, .height]
            nativeContentView.addSubview(controller.view)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        controller.windowDidAttach()
        openPendingDirectoryURLs()
        if selfTestCommand == nil {
            checkForUpdates()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = openDirectoryURLs(from: urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openDirectoryURLs(from: [URL(fileURLWithPath: filename)])
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let didOpen = openDirectoryURLs(from: filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: didOpen ? .success : .failure)
    }

    private func openDirectoryURLs(from urls: [URL]) -> Bool {
        let directoryURLs = urls.compactMap(Self.directoryURL)
        guard !directoryURLs.isEmpty else { return false }

        if controller == nil {
            pendingDirectoryURLs.append(contentsOf: directoryURLs)
            return true
        }

        openDirectoryURLs(directoryURLs)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.windowDidBecomeActive()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.windowDidBecomeActive()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.beginWindowResizeTooltip()
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.updateWindowResizeTooltip()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        controller?.endWindowResizeTooltip()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateCheckTask?.cancel()
        controller?.stopAllSessions()
    }

    private func checkForUpdates() {
        guard stagedUpdate == nil, updateCheckTask == nil else { return }
        updateCheckTask = Task { @MainActor in
            defer { updateCheckTask = nil }
            do {
                guard !Task.isCancelled, let update = try await updater.check() else {
                    return
                }
                stagedUpdate = update
                controller?.setUpdateStaged(true)
            } catch {
                NSLog("Vaultty update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func confirmInstallStagedUpdate() {
        guard let stagedUpdate else { return }

        let alert = NSAlert()
        alert.messageText = "Install update?"
        alert.informativeText = "Vaultty will quit, install \(stagedUpdate.assetName), and relaunch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Cancel")

        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.install(stagedUpdate)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            install(stagedUpdate)
        }
    }

    private func install(_ update: Update) {
        controller?.setUpdateInstallInProgress(true)
        Task { @MainActor in
            do {
                try await update.installAndRelaunch()
            } catch {
                controller?.setUpdateInstallInProgress(false)
                presentUpdateInstallError(error)
            }
        }
    }

    private func presentUpdateInstallError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Update failed"
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func closeActiveTabOrWindow(_ sender: Any?) {
        guard let controller else {
            window?.performClose(sender)
            return
        }
        controller.closeActiveTabOrWindow(sender)
    }

    @objc private func newTab(_ sender: Any?) {
        controller?.newTab(sender)
    }

    @objc private func clearActiveTab(_ sender: Any?) {
        controller?.clearActiveTab(sender)
    }

    @objc private func reopenClosedTab(_ sender: Any?) {
        controller?.reopenClosedTab(sender)
    }

    @objc private func killClosedTabs(_ sender: Any?) {
        controller?.killClosedTabs(sender)
    }

    @objc private func manageSSHHosts(_ sender: Any?) {
        let stored = loadSSHHosts()
        let form = makeSSHHostPanel(hosts: stored.hosts)
        let panel = form.panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard response == .OK else { return }

        let hostname = form.hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            NSSound.beep()
            return
        }

        let alias = form.aliasField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = form.userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let helperPath = form.helperField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(form.portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        var updated = stored
        updated.hosts.append(StoredSSHHost(
            id: UUID().uuidString,
            alias: alias.isEmpty ? hostname : alias,
            hostname: hostname,
            user: user.isEmpty ? NSUserName() : user,
            port: port,
            remoteHelperPath: helperPath.isEmpty
                ? "~/Library/Application Support/Vaultty/vaultty-session-bridge"
                : helperPath,
            enrolled: false
        ))
        saveSSHHosts(updated)
    }

    private struct SSHHostPanelForm {
        var panel: NSPanel
        var aliasField: NSTextField
        var hostField: NSTextField
        var userField: NSTextField
        var portField: NSTextField
        var helperField: NSTextField
    }

    private func makeSSHHostPanel(hosts: [StoredSSHHost]) -> SSHHostPanelForm {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Manage SSH Hosts"
        panel.isMovableByWindowBackground = true
        panel.preventsApplicationTerminationWhenModal = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let title = NSTextField(labelWithString: "Manage SSH Hosts")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let summary = NSTextField(labelWithString: sshHostSummary(hosts))
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byWordWrapping
        summary.maximumNumberOfLines = 3
        summary.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let aliasField = textField(placeholder: "workstation")
        let hostField = textField(placeholder: "host.example.com or SSH config alias")
        let userField = textField(placeholder: NSUserName())
        let portField = textField(placeholder: "22")
        portField.stringValue = "22"
        let helperField = textField(placeholder: "~/Library/Application Support/Vaultty/vaultty-session-bridge")

        let grid = NSGridView(views: [
            [formLabel("Alias"), aliasField],
            [formLabel("Host"), hostField],
            [formLabel("User"), userField],
            [formLabel("Port"), portField],
            [formLabel("Bridge"), helperField]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let bridgeNote = NSTextField(labelWithString: "Hosts stay unenrolled until the forced-command bridge installer is implemented.")
        bridgeNote.font = .systemFont(ofSize: 12)
        bridgeNote.textColor = .tertiaryLabelColor
        bridgeNote.lineBreakMode = .byWordWrapping
        bridgeNote.maximumNumberOfLines = 2
        bridgeNote.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Close", target: self, action: #selector(cancelModalPanel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "Add Host", target: self, action: #selector(acceptModalPanel(_:)))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [cancelButton, addButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, summary, separator, grid, bridgeNote, buttonStack] {
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 560),
            contentView.heightAnchor.constraint(equalToConstant: 420),

            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),

            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),

            separator.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            separator.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 18),

            grid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            grid.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 18),

            aliasField.widthAnchor.constraint(equalToConstant: 390),
            hostField.widthAnchor.constraint(equalTo: aliasField.widthAnchor),
            userField.widthAnchor.constraint(equalTo: aliasField.widthAnchor),
            portField.widthAnchor.constraint(equalTo: aliasField.widthAnchor),
            helperField.widthAnchor.constraint(equalTo: aliasField.widthAnchor),

            bridgeNote.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            bridgeNote.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            bridgeNote.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),

            buttonStack.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            buttonStack.widthAnchor.constraint(equalToConstant: 240),
            cancelButton.heightAnchor.constraint(equalToConstant: 32),
            addButton.heightAnchor.constraint(equalTo: cancelButton.heightAnchor)
        ])

        panel.initialFirstResponder = hostField

        return SSHHostPanelForm(
            panel: panel,
            aliasField: aliasField,
            hostField: hostField,
            userField: userField,
            portField: portField,
            helperField: helperField
        )
    }

    private func formLabel(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
        return field
    }

    private func textField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    @objc private func acceptModalPanel(_ sender: Any?) {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelModalPanel(_ sender: Any?) {
        NSApp.stopModal(withCode: .cancel)
    }

    private func sshHostSummary(_ hosts: [StoredSSHHost]) -> String {
        guard !hosts.isEmpty else {
            return "No SSH hosts are configured. Added hosts are stored but remain unenrolled until a forced-command bridge installer is implemented."
        }
        let lines = hosts.map { host in
            let status = host.enrolled ? "enrolled" : "not enrolled"
            return "\(host.alias): \(host.user)@\(host.hostname):\(host.port) (\(status))"
        }
        return lines.joined(separator: "\n")
    }

    private func loadSSHHosts() -> StoredSSHHosts {
        let url = sshHostsURL()
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredSSHHosts.self, from: data)
        else {
            return StoredSSHHosts(hosts: [])
        }
        return stored
    }

    private func saveSSHHosts(_ hosts: StoredSSHHosts) {
        do {
            let url = sshHostsURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(hosts)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not save SSH hosts"
            alert.runModal()
        }
    }

    private func sshHostsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Vaultty", isDirectory: true)
            .appendingPathComponent("hosts.json", isDirectory: false)
    }

    @objc private func selectPreviousTab(_ sender: Any?) {
        controller?.selectPreviousTab(sender)
    }

    @objc private func selectNextTab(_ sender: Any?) {
        controller?.selectNextTab(sender)
    }

    private func openPendingDirectoryURLs() {
        guard !pendingDirectoryURLs.isEmpty else { return }
        let directoryURLs = pendingDirectoryURLs
        pendingDirectoryURLs.removeAll()
        openDirectoryURLs(directoryURLs)
    }

    private func openDirectoryURLs(_ directoryURLs: [URL]) {
        guard let controller else {
            pendingDirectoryURLs.append(contentsOf: directoryURLs)
            return
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for url in directoryURLs {
            controller.newTab(at: url)
        }
    }

    private static func directoryURL(from url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return standardizedURL
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu(title: "Main Menu")
        menu.addItem(makeAppMenuItem())
        menu.addItem(makeEditMenuItem())
        menu.addItem(makeWindowMenuItem())
        return menu
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Vaultty")
        let appName = ProcessInfo.processInfo.processName

        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appItem.submenu = appMenu
        return appItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(.separator())
        let clearItem = editMenu.addItem(
            withTitle: "Clear Tab",
            action: #selector(clearActiveTab(_:)),
            keyEquivalent: "k"
        )
        clearItem.target = self

        editItem.submenu = editMenu
        return editItem
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")

        let newTabItem = windowMenu.addItem(
            withTitle: "New Tab",
            action: #selector(newTab(_:)),
            keyEquivalent: "t"
        )
        newTabItem.target = self
        let reopenClosedTabItem = windowMenu.addItem(
            withTitle: "Reopen Closed Tab",
            action: #selector(reopenClosedTab(_:)),
            keyEquivalent: "T"
        )
        reopenClosedTabItem.keyEquivalentModifierMask = [.command, .shift]
        reopenClosedTabItem.target = self
        let manageHostsItem = windowMenu.addItem(
            withTitle: "Manage SSH Hosts...",
            action: #selector(manageSSHHosts(_:)),
            keyEquivalent: ""
        )
        manageHostsItem.target = self
        windowMenu.addItem(.separator())

        let previousTabItem = windowMenu.addItem(
            withTitle: "Select Previous Tab",
            action: #selector(selectPreviousTab(_:)),
            keyEquivalent: "["
        )
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.target = self

        let nextTabItem = windowMenu.addItem(
            withTitle: "Select Next Tab",
            action: #selector(selectNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = self
        windowMenu.addItem(.separator())

        let closeItem = windowMenu.addItem(
            withTitle: "Close",
            action: #selector(closeActiveTabOrWindow(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = self
        let killClosedTabsItem = windowMenu.addItem(
            withTitle: "Kill Closed Tabs...",
            action: #selector(killClosedTabs(_:)),
            keyEquivalent: ""
        )
        killClosedTabsItem.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )

        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return windowItem
    }
}

private extension NSToolbar.Identifier {
    static let vaulttyTitlebar = NSToolbar.Identifier("com.automicvault.vaultty.titlebar")
}

@main
private enum VaulttyApplication {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.appearance = NSAppearance(named: .darkAqua)
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
