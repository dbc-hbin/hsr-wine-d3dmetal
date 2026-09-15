import AppKit
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "HSR Wine D3DMetal Installer"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private enum CLIAction {
    case install
    case restore
    case uninstall
}

private struct CLIOptions {
    var action: CLIAction = .install
    var explicitAction: CLIAction?
    var appPath: String?
    var supportPath: String?
}

private let usage = """
Usage: hsr-wine-installer (--cli | --install | --restore | --uninstall) [--app-path PATH] [--support-path PATH]

Installs the bundled prebuilt Wine runtime and registers it in Yaagl's Wine menu.
Use --restore to restore Yaagl's prior Wine registration from its installer backup.
Use --uninstall to remove only this installer's managed Wine, menu registration, and cached archive; the game and prefix are preserved.
"""

private func parseCLI(arguments: [String]) throws -> CLIOptions? {
    guard !arguments.isEmpty else {
        return nil
    }

    var options = CLIOptions()
    var index = 0
    var sawCLIOption = false

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--help", "-h":
            guard arguments.count == 1 else {
                throw CLIError("--help cannot be combined with other options.")
            }
            print(usage)
            exit(EXIT_SUCCESS)
        case "--cli":
            sawCLIOption = true
        case "--install":
            sawCLIOption = true
            guard options.explicitAction == nil else {
                throw CLIError("Only one of --install, --restore, or --uninstall may be specified.")
            }
            options.action = .install
            options.explicitAction = .install
        case "--restore":
            sawCLIOption = true
            guard options.explicitAction == nil else {
                throw CLIError("Only one of --install, --restore, or --uninstall may be specified.")
            }
            options.action = .restore
            options.explicitAction = .restore
        case "--uninstall":
            sawCLIOption = true
            guard options.explicitAction == nil else {
                throw CLIError("Only one of --install, --restore, or --uninstall may be specified.")
            }
            options.action = .uninstall
            options.explicitAction = .uninstall
        case "--app-path", "--support-path":
            sawCLIOption = true
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw CLIError("\(argument) requires a path.")
            }
            let path = (arguments[index] as NSString).expandingTildeInPath
            if argument == "--app-path" {
                guard options.appPath == nil else {
                    throw CLIError("--app-path may only be specified once.")
                }
                options.appPath = path
            } else {
                guard options.supportPath == nil else {
                    throw CLIError("--support-path may only be specified once.")
                }
                options.supportPath = path
            }
        default:
            throw CLIError("Unknown option: \(argument)")
        }
        index += 1
    }

    guard sawCLIOption else {
        throw CLIError("No CLI action was specified.")
    }
    return options
}

private struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private func runCLI(_ options: CLIOptions) -> Never {
    print("=== HSR Wine D3DMetal Installer (CLI Mode) ===")
    let engine = InstallerEngine()
    if let appPath = options.appPath {
        engine.appPath = appPath
    }
    if let supportPath = options.supportPath {
        engine.supportPath = supportPath
    }

    var isDone = false
    var exitCode: Int32 = EXIT_SUCCESS
    let completion: (Bool, String) -> Void = { success, message in
        print(success ? "\n[SUCCESS] \(message)" : "\n[ERROR] \(message)")
        exitCode = success ? EXIT_SUCCESS : EXIT_FAILURE
        isDone = true
    }

    switch options.action {
    case .install:
        engine.install(completion: completion)
    case .restore:
        engine.restore(completion: completion)
    case .uninstall:
        engine.uninstall(completion: completion)
    }

    while !isDone {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }
    exit(exitCode)
}

do {
    if let options = try parseCLI(arguments: Array(CommandLine.arguments.dropFirst())) {
        runCLI(options)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} catch {
    fputs("Error: \(error.localizedDescription)\n\n\(usage)\n", stderr)
    exit(EXIT_FAILURE)
}
