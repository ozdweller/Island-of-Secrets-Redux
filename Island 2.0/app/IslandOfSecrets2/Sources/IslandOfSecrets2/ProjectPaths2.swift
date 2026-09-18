import Foundation

/// Locates the Island of Secrets repo root (the folder containing both
/// `Island 2.0/engine/shell_ipc.py` and `data/rooms.json`) regardless of
/// how this app was launched -- `swift run` from this package's own
/// directory, Xcode's build/run location, or a double-clicked .app
/// bundle. Deliberately its own copy rather than a shared file with the
/// Classic app's `ProjectPaths.swift`: this is a separate SwiftPM
/// package (`Island 2.0/app/IslandOfSecrets2`), and per the project's
/// standing rule, nothing under the repo's original `app/`/`engine/`/
/// `data/`/`listing.bas` gets touched or shared-by-reference from 2.0 --
/// see docs/ISLAND2_PLAN.md. The search strategy itself is copied
/// faithfully from the Classic app's version since it's already proven
/// to work across all three launch paths there; only the "does this look
/// like the root" check and the default fallback path changed.
enum ProjectPaths2 {

    /// Search upward from a set of candidate starting points for a folder
    /// that looks like the repo root.
    static func findProjectRoot() -> URL? {
        let fm = FileManager.default

        func looksLikeRoot(_ url: URL) -> Bool {
            let shellIpc = url.appendingPathComponent("Island 2.0/engine/shell_ipc.py")
            let rooms = url.appendingPathComponent("data/rooms.json")
            return fm.fileExists(atPath: shellIpc.path) && fm.fileExists(atPath: rooms.path)
        }

        func searchUpward(from start: URL, maxLevels: Int = 8) -> URL? {
            var current = start
            for _ in 0...maxLevels {
                if looksLikeRoot(current) { return current }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
            return nil
        }

        // 1. An explicit override, for when the folder has moved.
        if let envPath = ProcessInfo.processInfo.environment["ISLAND_PROJECT_ROOT"] {
            let url = URL(fileURLWithPath: envPath)
            if looksLikeRoot(url) { return url }
        }

        // 2. Walk up from the current working directory (covers `swift
        //    run` invoked from this package's own directory).
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if let found = searchUpward(from: cwd) { return found }

        // 3. Walk up from the executable's own location (covers a built
        //    .app bundle launched from Finder, where cwd is often "/").
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if let found = searchUpward(from: exeURL.deletingLastPathComponent()) { return found }

        // 4. Last resort: the same well-known default location the
        //    Classic app's ProjectPaths.swift falls back to -- both apps
        //    live in the same repo.
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/MyApps/Island")
        if looksLikeRoot(fallback) { return fallback }

        return nil
    }
}
