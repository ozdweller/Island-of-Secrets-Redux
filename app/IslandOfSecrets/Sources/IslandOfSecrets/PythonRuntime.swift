import Foundation

/// Resolves which `python3` to run the game engine with.
///
/// `swift run`/Xcode dev builds have no bundled interpreter, so this
/// falls back to whatever `python3` is on PATH, exactly as before this
/// existed. A packaged release build (`scripts/package_app.sh`) embeds a
/// self-contained interpreter per architecture under
/// `Contents/Resources/python-runtime/<arch>/bin/python3` (from
/// indygreg's python-build-standalone, which doesn't ship universal2
/// builds) so a downloaded .app needs nothing installed -- no Xcode
/// Command Line Tools, no system Python -- to run.
enum PythonRuntime {

    /// Returns the executable to launch and the full argument list to
    /// pass it (the embedded interpreter is invoked directly; the PATH
    /// fallback goes through `/usr/bin/env python3` as before).
    static func launch(scriptPath: String, extraArguments: [String] = []) -> (executable: URL, arguments: [String]) {
        if let resourceURL = Bundle.main.resourceURL {
            let embedded = resourceURL
                .appendingPathComponent("python-runtime")
                .appendingPathComponent(currentArchitecture())
                .appendingPathComponent("bin/python3")
            if FileManager.default.fileExists(atPath: embedded.path) {
                return (embedded, [scriptPath] + extraArguments)
            }
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["python3", scriptPath] + extraArguments)
    }

    /// "arm64" on Apple silicon, "x86_64" on Intel -- matches the folder
    /// names `scripts/package_app.sh` embeds the two interpreters under.
    private static func currentArchitecture() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { rawPointer -> String in
            let charPointer = rawPointer.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: charPointer)
        }
        return machine.hasPrefix("arm64") ? "arm64" : "x86_64"
    }
}
