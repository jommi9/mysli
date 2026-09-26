import AppKit
import SwiftUI

/// Hosts `MainView` in a regular window. mysli normally lives in the menu
/// bar only; while this window is open it also shows in the Dock and ⌘-Tab,
/// and goes back to menu-bar-only when the window closes.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        let window = self.window ?? makeWindow()
        state.refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        state.refresh()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "mysli"
        window.contentViewController = NSHostingController(rootView: MainView(state: state))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("mysli.main")
        if !window.setFrameUsingName("mysli.main") {
            window.center()
        }
        self.window = window
        return window
    }

    /// App and Edit menus. Without a main menu, ⌘C/⌘V/⌘A and ⌘Q do nothing
    /// in the window, since AppKit routes those shortcuts through the menu.
    static func installMainMenu(onQuit: @escaping () -> Void) {
        let main = NSMenu()
        quitTarget.action = onQuit

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide mysli", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        // Quit goes through the app controller so a running recording is
        // finalized first.
        let quit = appMenu.addItem(withTitle: "Quit mysli", action: #selector(ClosureTarget.run), keyEquivalent: "q")
        quit.target = quitTarget
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private static let quitTarget = ClosureTarget()
}

/// Menu-item target that runs a closure.
@MainActor
final class ClosureTarget: NSObject {
    var action: () -> Void = {}
    @objc func run() { action() }
}
