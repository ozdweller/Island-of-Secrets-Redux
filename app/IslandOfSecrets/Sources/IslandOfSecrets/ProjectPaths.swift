import Foundation

/// Locates the Island of Secrets project root (the folder containing
/// `engine/play_ipc.py` and `listing.bas`) regardless of exactly how
/// this app was launched -- `swift run` from the package directory, Xcode's
/// own build/run location, or a double-clicked .app bundle.
enum ProjectPaths {

    /// Search upward from a set of candidate starting points for a folder
    /// that looks like the project root.
    static func findProjectRoot() -> URL? {
        let fm = FileManager.default

        func looksLikeRoot(_ url: URL) -> Bool {
            let engine = url.appendingPathComponent("engine/play_ipc.py")
            let listing = url.appendingPathComponent("listing.bas")
            return fm.fileExists(atPath: engine.path) && fm.fileExists(atPath: listing.path)
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

        // 2. A packaged release build: `scripts/package_app.sh` copies
        //    engine/, listing.bas and art/ straight into
        //    MyApp.app/Contents/Resources, which is a sibling of
        //    Contents/MacOS -- not an ancestor of it -- so the upward
        //    searches below can never find it on their own. Bundle.main
        //    only resolves to something meaningful inside a real .app
        //    bundle, so this is a no-op for `swift run`/Xcode.
        if let resourceURL = Bundle.main.resourceURL, looksLikeRoot(resourceURL) {
            return resourceURL
        }

        // 3. Walk up from the current working directory (covers `swift run`
        //    invoked from app/IslandOfSecrets, and Xcode runs that inherit
        //    a sensible cwd).
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if let found = searchUpward(from: cwd) { return found }

        // 4. Walk up from the executable's own location (covers a built
        //    .app bundle launched from Finder, where cwd is often "/").
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if let found = searchUpward(from: exeURL.deletingLastPathComponent()) { return found }

        // 5. Last resort: the well-known default location from setup.
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/MyApps/Island")
        if looksLikeRoot(fallback) { return fallback }

        return nil
    }
}
