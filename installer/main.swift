import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Wine 11.17 ZZZ DX12 Installer"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// CLI entrypoint if arguments contain --cli or --install
if CommandLine.arguments.contains("--cli") || CommandLine.arguments.contains("--install") {
    print("=== Wine 11.17 ZZZ DX12 Installer (CLI Mode) ===")
    let engine = InstallerEngine()
    var isDone = false
    var exitCode: Int32 = 0

    engine.install { success, message in
        if success {
            print("\n[SUCCESS] \(message)")
            exitCode = 0
        } else {
            print("\n[ERROR] \(message)")
            exitCode = 1
        }
        isDone = true
    }

    while !isDone {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }
    exit(exitCode)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
