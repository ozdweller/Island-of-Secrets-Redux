import Foundation
import Combine

/// One JSON line emitted by `Island 2.0/engine/shell_ipc.py`. See that
/// file's own docstring for the full protocol -- this mirrors it
/// field-for-field, the same "thin, deliberately dumb bridge" approach
/// as the Classic app's `GameEngine.swift`/`EngineTurn`, just against a
/// different (not backward-compatible, not trying to be) protocol shape
/// since 2.0 has no BASIC engine underneath it to stay compatible with.
private struct EngineTurn2: Decodable {
    let type: String
    let text: String?
    let room: Int?
    let roomDescription: String?
    let time: Int?
    let strength: Double?
    let wisdom: Double?
    let inventory: [Int]?
    let roomObjects: [Int]?
    let gameOver: Bool?
    let ending: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type, text, room, time, strength, wisdom, inventory, ending, message
        case roomDescription = "room_description"
        case roomObjects = "room_objects"
        case gameOver = "game_over"
    }
}

/// Runs `Island 2.0/engine/shell_ipc.py` as a subprocess and exposes the
/// game's state as published properties for SwiftUI to bind to. All the
/// actual game logic (intent parsing, rule evaluation, narration) stays
/// in Python, same "don't re-port already-tested logic into Swift"
/// reasoning as the Classic app's `GameEngine.swift` -- this is that
/// same shape of bridge, adapted to a different backend and a simpler
/// protocol (2.0's narration IS the transcript text, not an optional
/// second panel layered on top of a BASIC engine's own printed output,
/// so there's only ever one `text` per turn to show, not two).
final class GameEngine2: ObservableObject {

    @Published var transcript: [String] = []
    @Published var room: Int = 0
    @Published var roomDescription: String = ""
    @Published var time: Int = 1000
    @Published var strength: Double = 100
    @Published var wisdom: Double = 25
    @Published var inventory: [Int] = []
    @Published var roomObjects: [Int] = []
    @Published var isGameOver: Bool = false
    @Published var ending: String?
    @Published var launchError: String?

    /// Which Ollama model to use for both intent parsing and narration
    /// -- see `shell_ipc.py --model`. A single picker for both, same
    /// default as the value already live-validated in this project's
    /// 2.0-C/2.0-D spikes; `Island 2.0/engine/README.md` documents
    /// splitting these independently if that's ever worth doing here.
    var model: String = "llama3.1:8b"

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()

    func start() {
        guard let root = ProjectPaths2.findProjectRoot() else {
            launchError = """
                Couldn't find the Island 2.0 engine. Expected to find \
                "Island 2.0/engine/shell_ipc.py" and "data/rooms.json" \
                somewhere near this app. If you've moved the Island \
                folder, set the ISLAND_PROJECT_ROOT environment variable \
                (in Xcode: Product > Scheme > Edit Scheme > Run > \
                Arguments) to its path.
                """
            return
        }

        let scriptURL = root.appendingPathComponent("Island 2.0/engine/shell_ipc.py")

        // Inside a packaged .app, Contents/Resources (where `root` points)
        // is meant to be read-only-ish -- writing a save file there risks
        // invalidating the ad-hoc code signature and isn't where a mac app
        // is supposed to keep its state anyway. Redirect to the standard
        // per-user Application Support location in that case; `swift
        // run`/Xcode dev builds keep saving next to the engine, unchanged.
        var extraArguments: [String] = []
        if let resourceURL = Bundle.main.resourceURL, root.standardizedFileURL == resourceURL.standardizedFileURL,
           let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let saveDir = appSupport.appendingPathComponent("Island of Secrets 2", isDirectory: true)
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            extraArguments = ["--save-path", saveDir.appendingPathComponent("island2_save.json").path]
        }

        let (pythonExecutable, pythonArguments) = PythonRuntime2.launch(
            scriptPath: scriptURL.path,
            extraArguments: ["--model", model] + extraArguments
        )

        let proc = Process()
        proc.executableURL = pythonExecutable
        proc.arguments = pythonArguments
        proc.currentDirectoryURL = root.appendingPathComponent("Island 2.0/engine")

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleIncoming(data)
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                FileHandle.standardError.write(text.data(using: .utf8) ?? Data())
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.stdinPipe = stdin
        } catch {
            launchError = "Couldn't launch the Python engine: \(error.localizedDescription). Make sure python3 is on your PATH."
        }
    }

    func send(_ command: String) {
        guard let stdin = stdinPipe, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        transcript.append("> \(command)")
        let payload: [String: String] = ["cmd": command]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = data
        line.append(0x0A) // newline
        stdin.fileHandleForWriting.write(line)
    }

    /// `shell.py`'s Shell.take_turn() already treats the literal text
    /// "save"/"load" as meta-command aliases that bypass the LLM
    /// entirely and always work instantly (see shell.py's own module
    /// docstring) -- so unlike the Classic app's saveGame()/loadGame(),
    /// there's no separate subprocess command or "PRESS RETURN"
    /// auto-continue dance needed here. These are just send(_:) with a
    /// fixed string.
    func saveGame() {
        guard !isGameOver else { return }
        send("save")
    }

    func loadGame() {
        guard !isGameOver else { return }
        send("load")
    }

    /// Same "just send(_:) the literal alias" shape as saveGame()/
    /// loadGame() above -- shell.py's `_META_ALIASES` maps "help" to a
    /// fixed, deterministic `HELP_TEXT` response that bypasses the LLM
    /// entirely (see shell.py's own module docstring on why HELP is a
    /// pure UI query like INFO). Unlike save/load there's no reason to
    /// block this once the game is over -- asking what the commands
    /// were is harmless after an ending, so no `isGameOver` guard here.
    func requestHelp() {
        send("help")
    }

    func stop() {
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    // MARK: - stdout parsing

    private func handleIncoming(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineRange = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<newlineRange.upperBound)
            guard !lineData.isEmpty else { continue }
            processLine(lineData)
        }
    }

    private func processLine(_ lineData: Data) {
        guard let turn = try? JSONDecoder().decode(EngineTurn2.self, from: lineData) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch turn.type {
            case "turn":
                if let text = turn.text, !text.isEmpty {
                    self.transcript.append(text)
                }
                if let r = turn.room { self.room = r }
                if let d = turn.roomDescription { self.roomDescription = d }
                if let t = turn.time { self.time = t }
                if let s = turn.strength { self.strength = s }
                if let w = turn.wisdom { self.wisdom = w }
                if let inv = turn.inventory { self.inventory = inv }
                if let objs = turn.roomObjects { self.roomObjects = objs }
                if let over = turn.gameOver { self.isGameOver = over }
                if let e = turn.ending { self.ending = e }
            case "error":
                self.launchError = turn.message ?? "unknown engine error"
            default:
                break
            }
        }
    }
}
