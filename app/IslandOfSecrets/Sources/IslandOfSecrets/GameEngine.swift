import Foundation
import Combine

/// One JSON line emitted by engine/play_ipc.py. See io_ipc.py's docstring
/// for the full protocol -- this mirrors it field-for-field.
private struct EngineTurn: Decodable {
    let type: String
    let text: String?
    let room: Int?
    let time: Int?
    let strength: Double?
    let wisdom: Double?
    let food: Int?
    let drink: Int?
    let message: String?
    let inventory: [Int]?
    let roomObjects: [Int]?
}

/// Runs engine/play_ipc.py as a subprocess and exposes the game's state as
/// published properties for SwiftUI to bind to. All the actual game logic
/// (the verified BASIC interpreter) stays in Python -- this is a thin,
/// deliberately dumb bridge so we never have to re-port the already
/// bug-fixed engine into Swift.
final class GameEngine: ObservableObject {

    @Published var transcript: [String] = []
    @Published var room: Int = 0
    @Published var time: Int = 1000
    @Published var strength: Double = 100
    @Published var wisdom: Double = 35
    @Published var food: Int = 0
    @Published var drink: Int = 0
    @Published var inventory: [Int] = []
    /// Objects/characters (item ids 1-43) present in the current room, per
    /// Phase 7.1's io_ipc.py addition -- same L()-array technique already
    /// used for `inventory`, just filtered to "here" instead of "carried".
    /// Feeds LoreStore's "have I met this character yet" tracking.
    @Published var roomObjects: [Int] = []
    @Published var isGameOver: Bool = false
    /// True while we've sent XSAVE/XLOAD and are waiting for the game's
    /// generic "PRESS RETURN" pause so we can auto-acknowledge it -- see
    /// saveGame()/loadGame() below.
    private var pendingSaveLoadContinue = false
    @Published var launchError: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()

    func start() {
        guard let root = ProjectPaths.findProjectRoot() else {
            launchError = """
                Couldn't find the game engine. Expected to find \
                engine/play_ipc.py and listing.bas somewhere near \
                this app. If you've moved the Island folder, set the \
                ISLAND_PROJECT_ROOT environment variable (in Xcode: \
                Product > Scheme > Edit Scheme > Run > Arguments) to its \
                path.
                """
            return
        }

        let scriptURL = root.appendingPathComponent("engine/play_ipc.py")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptURL.path]
        proc.currentDirectoryURL = root

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

    /// Appends a UI-originated line to the transcript -- e.g. Phase 7.5's
    /// "(interpreting as: TAKE APPLE)" note -- without going anywhere near
    /// the engine subprocess. Purely cosmetic; never affects game state.
    func appendNote(_ text: String) {
        transcript.append(text)
    }

    func send(_ command: String) {
        guard let stdin = stdinPipe, !command.isEmpty else { return }
        let payload: [String: String] = ["cmd": command]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = data
        line.append(0x0A) // newline
        stdin.fileHandleForWriting.write(line)
    }

    /// Triggers the game's own SAVE command (writes to data/savegame.json).
    /// The BASIC listing pauses once with a generic "PRESS RETURN" prompt
    /// partway through -- pendingSaveLoadContinue lets us swallow that
    /// automatically so Save/Load feel like a single action from the menu,
    /// instead of requiring a second keypress.
    func saveGame() {
        guard !isGameOver, !pendingSaveLoadContinue else { return }
        pendingSaveLoadContinue = true
        send("XSAVE")
    }

    /// Triggers the game's own LOAD command, restoring room/inventory/stats
    /// from the last save. Same "PRESS RETURN" auto-continue as saveGame().
    func loadGame() {
        guard !isGameOver, !pendingSaveLoadContinue else { return }
        pendingSaveLoadContinue = true
        send("XLOAD")
    }

    /// Sends an empty command -- used only to auto-acknowledge the game's
    /// "PRESS RETURN" pause after XSAVE/XLOAD. send(_:) deliberately
    /// refuses empty commands from the text field, so this bypasses it.
    private func sendContinue() {
        guard let stdin = stdinPipe else { return }
        let payload: [String: String] = ["cmd": ""]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = data
        line.append(0x0A)
        stdin.fileHandleForWriting.write(line)
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
        guard let turn = try? JSONDecoder().decode(EngineTurn.self, from: lineData) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch turn.type {
            case "turn":
                if let text = turn.text, !text.isEmpty {
                    self.transcript.append(text)
                }
                if let r = turn.room { self.room = r }
                if let t = turn.time { self.time = t }
                if let s = turn.strength { self.strength = s }
                if let w = turn.wisdom { self.wisdom = w }
                if let f = turn.food { self.food = f }
                if let d = turn.drink { self.drink = d }
                if let inv = turn.inventory { self.inventory = inv }
                if let objs = turn.roomObjects { self.roomObjects = objs }
                if self.pendingSaveLoadContinue {
                    self.pendingSaveLoadContinue = false
                    self.sendContinue()
                }
            case "error":
                self.transcript.append("\n[engine error] " + (turn.message ?? "unknown error"))
            case "gameover":
                self.isGameOver = true
            default:
                break
            }
        }
    }
}
