import SwiftUI
import AppKit

/// Deliberately simpler than the Classic app's ContentView.swift --
/// per docs/ISLAND2_PLAN.md's own framing for 2.0-E ("likely simpler
/// than the current one in some ways, since there's no Classic-mode
/// raw-text fallback needed"). No Lore codex, no hint sheet, no
/// NL-assist retry logic: 2.0's narration.py already *is* the primary
/// text for every turn (not an optional second panel layered on top
/// of a separately-authoritative BASIC transcript), and its own hard
/// rules (see narration.py's SYSTEM_PROMPT) are what keep it
/// grounded, not a client-side safety net. This is a first sketch,
/// not a claim that 2.0 will never want its own richer UI later.
///
/// It does carry an illustration panel (`illustrationPanel` below),
/// wired to the same shared `art/` folder the Classic app already
/// reads via its own `RoomArt.swift` -- see `RoomArt2.swift` for why
/// this reads the shared folder rather than a 2.0-owned copy. Every
/// piece of that art was reviewed against `docs/ART_CLUES.md` before
/// this was wired in; a short list of rooms/characters flagged there
/// as needing a redraw will simply start looking right the moment
/// the author drops in a corrected PNG at the same path -- no app changes
/// needed either way.
struct ContentView2: View {
    @EnvironmentObject var engine: GameEngine2
    @State private var commandText: String = ""
    @FocusState private var inputFocused: Bool
    @State private var showCloseConfirmation = false

    /// Which model shell_ipc.py is launched with -- read once at
    /// start() time (see GameEngine2.start()), so changing this after
    /// the subprocess is already running has no effect until the next
    /// launch. A picker here is still useful for choosing *before*
    /// pressing Play. Options are the same shortlist the Classic app's
    /// narration picker offers, since both draw from the same pool of
    /// models this project has already spiked against.
    @AppStorage("island2Model") private var selectedModel = "llama3.1:8b"
    @State private var hasStarted = false
    @State private var isCheckingOllama = false
    /// Set when the pre-Start check (see OllamaStatus2.swift) finds Ollama
    /// not running or the chosen model not pulled. nil means either the
    /// check hasn't run yet or it came back fine.
    @State private var ollamaProblem: OllamaCheckResult2?
    private static let availableModels = [
        "llama3.1:8b", "qwen2.5vl:7b", "qwen2.5:3b", "mistral-nemo:latest",
        "gemma2:27b", "qwen3.5:35b",
    ]

    /// Roughly a 6x4" print at typical screen scaling (~96pt/inch) --
    /// landscape, to match the ~4:3 aspect ratio the generated room art
    /// was actually prompted at (see docs/GROK_IMAGINE_ART_FIX_PROMPTS.md,
    /// "Landscape orientation, roughly 4:3"). The author asked for the image
    /// to read as a real illustration up top, not a sidebar thumbnail --
    /// this is that, with the transcript moved below it instead of beside
    /// it.
    private static let illustrationSize = CGSize(width: 576, height: 384)

    var body: some View {
        Group {
            if let error = engine.launchError {
                launchErrorView(error)
            } else if !hasStarted {
                startScreen
            } else {
                gameView
            }
        }
        .alert(
            ollamaProblem == .modelMissing ? "Model not found" : "Ollama isn't running",
            isPresented: Binding(
                get: { ollamaProblem != nil },
                set: { if !$0 { ollamaProblem = nil } }
            )
        ) {
            Button("Open Ollama.com") {
                NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
            }
            // In case this check itself is wrong -- e.g. a custom
            // OLLAMA_HOST reachable from Python but not reachable the same
            // way from here -- don't make it impossible to proceed.
            Button("Start Anyway") { beginGame() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ollamaAlertMessage)
        }
    }

    /// Wording for the alert above -- its own property since the
    /// model-missing case needs to interpolate the exact pull command.
    private var ollamaAlertMessage: String {
        switch ollamaProblem {
        case .notRunning, .none:
            return "Island of Secrets 2.0 needs Ollama running locally. Download it from ollama.com, open it once, then try again."
        case .modelMissing:
            return "Ollama is running, but \"\(selectedModel)\" hasn't been pulled yet. Open Terminal and run:\n\nollama pull \(selectedModel)"
        case .ok:
            return ""
        }
    }

    private func beginGame() {
        engine.model = selectedModel
        engine.start()
        hasStarted = true
    }

    // MARK: - pre-launch model picker

    private var startScreen: some View {
        VStack(spacing: 16) {
            Text("Island of Secrets 2.0")
                .font(.largeTitle.bold())
            Text("Choose the model to run intent parsing and narration with, then start.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Model", selection: $selectedModel) {
                ForEach(Self.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            Button(isCheckingOllama ? "Checking..." : "Start") {
                Task {
                    isCheckingOllama = true
                    let result = await OllamaStatus2.check(model: selectedModel)
                    isCheckingOllama = false
                    if result == .ok {
                        beginGame()
                    } else {
                        ollamaProblem = result
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCheckingOllama)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }

    private func launchErrorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Couldn't start the game")
                .font(.headline)
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
    }

    // MARK: - main game view

    private var gameView: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            illustrationPanel
            Divider()
            transcriptPanel
            Divider()
            inputBar
        }
        .frame(minWidth: 700, minHeight: 760)
        .onDisappear { engine.stop() }
        .alert("Close Island of Secrets 2.0?", isPresented: $showCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Close", role: .destructive) { closeGame() }
        } message: {
            Text("Any unsaved progress will be lost. Use Save Game first if you want to keep it.")
        }
    }

    private func closeGame() {
        engine.stop()
        NSApplication.shared.terminate(nil)
    }

    private var statusBar: some View {
        HStack(spacing: 24) {
            statLabel("Time", "\(engine.time)")
            statLabel("Strength", String(format: "%.0f", engine.strength))
            statLabel("Wisdom", String(format: "%.0f", engine.wisdom))
            Spacer()
            // Sends the same literal "help" alias typing it would --
            // see GameEngine2.requestHelp()/shell.py's HELP_TEXT. Not
            // disabled on game-over: asking what the commands were is
            // harmless after an ending, unlike Save/Load.
            Button {
                engine.requestHelp()
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show what you can do")
            Button("Save") { engine.saveGame() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.isGameOver)
            Button("Load") { engine.loadGame() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.isGameOver)
            Button {
                MapWindowController2.shared.show(nextTo: NSApplication.shared.keyWindow)
            } label: {
                Label("Map", systemImage: "map")
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Grandpa's map in its own window")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func statLabel(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).monospacedDigit())
        }
    }

    private var transcriptPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // The first turn has to wait on the LLM's opening
                    // narration before anything appears -- without this,
                    // that wait just looks like a blank, possibly-frozen
                    // window. This clears itself the instant the first
                    // "turn" message arrives and engine.transcript stops
                    // being empty.
                    if engine.transcript.isEmpty && !engine.isGameOver {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("The island is waking up... (first response can take a little while)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    ForEach(Array(engine.transcript.enumerated()), id: \.offset) { index, entry in
                        Text(entry)
                            .font(entry.hasPrefix("> ") ? .system(.body, design: .monospaced).bold() : .body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if engine.isGameOver {
                        endingBanner
                            // One past the last real transcript index, so
                            // this is always a distinct, valid Int id --
                            // keeps scrollTo's target a single concrete
                            // type below instead of mixing String/Int in
                            // a ternary.
                            .id(engine.transcript.count)
                    }
                }
                .padding(16)
            }
            .onChange(of: engine.transcript.count) { _ in
                withAnimation {
                    if engine.isGameOver {
                        proxy.scrollTo(engine.transcript.count, anchor: .bottom)
                    } else if let last = engine.transcript.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Room art (falling back to a plain placeholder, same as the
    /// Classic app, when a room has no PNG yet) plus a strip of
    /// portraits for any named characters visibly present this turn.
    /// See `RoomArt2.swift` for how presence is computed and why the
    /// art itself lives outside `Island 2.0/`.
    ///
    /// Sized to `Self.illustrationSize` (~6x4" on screen) and centered
    /// above the transcript, rather than a narrow sidebar beside it --
    /// the illustration is meant to read as the room's picture, not a
    /// thumbnail. The whole panel is capped at `illustrationMaxHeight`
    /// and scrolls internally: the room image and (when present) a
    /// full-size character portrait were together taller than most
    /// windows, which was squeezing the transcript out entirely. Capping
    /// it here guarantees the transcript below always gets real space,
    /// while the room picture -- the thing you look at first each turn
    /// -- stays fully visible without scrolling; a character portrait,
    /// when there is one, is one scroll away rather than always
    /// competing for the same vertical space.
    private static let illustrationMaxHeight: CGFloat = illustrationSize.height + 90

    private var illustrationPanel: some View {
        ScrollView {
            VStack(spacing: 10) {
                Group {
                    if let image = RoomArt2.roomImage(for: engine.room) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                )
                            )
                            .id(engine.room)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.12))
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 36))
                                        .foregroundStyle(.tertiary)
                                    Text("No illustration yet")
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                }
                            )
                    }
                }
                .frame(width: Self.illustrationSize.width, height: Self.illustrationSize.height)
                .clipped()
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                .animation(.easeInOut(duration: 0.35), value: engine.room)

                let present = CharacterArt2.present(roomObjects: engine.roomObjects, room: engine.room)
                if !present.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("HERE")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        // Full-size portrait cards, same treatment as the room
                        // illustration above (same box, .fit not .fill, same
                        // corner radius and shadow) -- the author's call: these
                        // portraits are full Grok renders in their own right,
                        // not a supporting-cast footnote, so they get the same
                        // stage the room art gets rather than a small square
                        // crop. Square 1:1 portraits will letterbox slightly
                        // inside the wider 4:3 box; that's fine, it keeps every
                        // portrait's full frame visible instead of cropping it.
                        ScrollView(.horizontal, showsIndicators: present.count > 1) {
                            HStack(spacing: 24) {
                                ForEach(present, id: \.slug) { character in
                                    VStack(spacing: 6) {
                                        Group {
                                            if let image = RoomArt2.characterImage(slug: character.slug) {
                                                Image(nsImage: image)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                            } else {
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(Color.gray.opacity(0.12))
                                            }
                                        }
                                        .frame(width: Self.illustrationSize.width, height: Self.illustrationSize.height)
                                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                                        Text(character.name)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: Self.illustrationSize.width, alignment: .leading)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: Self.illustrationMaxHeight)
    }

    private var endingBanner: some View {
        VStack(spacing: 6) {
            Divider()
            Text("THE END")
                .font(.headline)
            if let ending = engine.ending {
                Text(ending)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var inputBar: some View {
        HStack {
            TextField("What will you do?", text: $commandText)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .disabled(engine.isGameOver)
                .onSubmit(submitCommand)
            Button("Send", action: submitCommand)
                .disabled(engine.isGameOver || commandText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .onAppear { inputFocused = true }
    }

    private func submitCommand() {
        let trimmed = commandText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        engine.send(trimmed)
        commandText = ""
    }
}
