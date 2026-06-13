import AppKit
import AppUpdater

private enum AppWindowMetrics {
    static let defaultContentSize = NSSize(width: 1120, height: 760)
    static let minimumContentSize = NSSize(width: 760, height: 480)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
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
        window.isMovableByWindowBackground = true
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
