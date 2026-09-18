import SwiftUI
import AppKit

/// Same "force regular Dock/Cmd-Tab presence" fix as the Classic app's
/// AppDelegate, needed for the same reason: a bare SwiftPM executable
/// (`swift run`) doesn't reliably get treated as a normal GUI app
/// without this. No app-icon loading here yet -- 2.0 doesn't have its
/// own `art/app_icon.png` equivalent; falls back to the default SwiftUI
/// app icon until one exists.
final class AppDelegate2: NSObject, NSApplicationDelegate {
    var engine: GameEngine2?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }
}

@main
struct IslandOfSecrets2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate2.self) private var appDelegate
    @StateObject private var engine = GameEngine2()

    var body: some Scene {
        WindowGroup("Island of Secrets 2.0") {
            ContentView2()
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
