import SwiftUI
import AppKit

/// Sets the Dock/Cmd-Tab icon at launch by loading `art/app_icon.png`
/// directly, rather than relying on Info.plist bundle packaging (which
/// SwiftPM executables run via `swift run` or a bare Xcode scheme don't
/// reliably pick up). This works the same way regardless of how the app
/// was launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the game view appears (see IslandOfSecretsApp.body below),
    /// so applicationWillTerminate can shut the Python subprocess down
    /// cleanly no matter how the app is quit -- Cmd+Q, Dock > Quit, or the
    /// in-window Close button (which also calls engine.stop() itself, but
    /// this is a catch-all for every other path too).
    var engine: GameEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force a regular (Dock + Cmd-Tab visible) app presence. When this
        // is launched as a bare SwiftPM executable (via `swift run`, or the
        // Automator/launch.command wrapper used for double-click launching),
        // macOS doesn't reliably treat it as a normal GUI app on its own --
        // it can come up with no Dock icon and no Cmd-Tab entry. Setting the
        // activation policy explicitly fixes that regardless of launch path.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard let root = ProjectPaths.findProjectRoot() else { return }
        let url = root.appendingPathComponent("art/app_icon.png")
        if let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }
}

@main
struct IslandOfSecretsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = GameEngine()

    /// launch.command's Classic/Cyber picker sets ISLAND_MODE and hands it
    /// to `swift run` as an environment variable; this applies it to the
    /// same @AppStorage-backed UserDefaults keys ContentView's toggles
    /// read (see ContentView.swift's narrationEnabled/nlAssistEnabled),
    /// as the very first thing that runs -- before ContentView's own
    /// @AppStorage property wrappers ever read a value -- so the app
    /// opens directly into whichever mode was picked, no manual toggling
    /// needed. A plain `swift run`/Xcode launch with no ISLAND_MODE set
    /// just keeps whatever was left on from last time, same as before
    /// this existed.
    private static let launchMode: String? = {
        let env = ProcessInfo.processInfo.environment["ISLAND_MODE"]?.lowercased()
        switch env {
        case "cyber":
            UserDefaults.standard.set(true, forKey: "islandNarrationEnabled")
            UserDefaults.standard.set(true, forKey: "islandNLAssistEnabled")
        case "classic":
            UserDefaults.standard.set(false, forKey: "islandNarrationEnabled")
            UserDefaults.standard.set(false, forKey: "islandNLAssistEnabled")
        default:
            break
        }
        return env
    }()

    private var windowTitle: String {
        switch Self.launchMode {
        case "cyber": return "Island of Secrets — Cyber"
        case "classic": return "Island of Secrets — Classic"
        default: return "Island of Secrets"
        }
    }

    var body: some Scene {
        WindowGroup(windowTitle) {
            ContentView()
                .environmentObject(engine)
                .onAppear { appDelegate.engine = engine }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save Game") {
                    engine.saveGame()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(engine.isGameOver)

                Button("Load Game") {
                    engine.loadGame()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(engine.isGameOver)
            }
        }
    }
}
