import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var engine: GameEngine
    @State private var commandText: String = ""
    @FocusState private var inputFocused: Bool
    @State private var showCloseConfirmation = false
    /// Phase 7.4 lore codex -- lives here rather than on GameEngine since
    /// it's a pure UI-side accumulator over what the engine already
    /// publishes, not part of the engine/game-state bridge itself.
    @StateObject private var lore = LoreStore()
    @State private var showLore = false

    /// Phase 7.3 -- local-model narration. Off by default (classic text
    /// only); the toggle and model picker live in the status bar.
    @StateObject private var narration = NarrationService()
    @AppStorage("islandNarrationEnabled") private var narrationEnabled = false
    @AppStorage("islandNarrationModel") private var narrationModel = "llama3.1:8b"
    @State private var previousStoryPanelIDs: Set<Int> = []
    private static let availableModels = [
        "qwen2.5:3b", "llama3.1:8b", "mistral-nemo:latest",
        "gemma2:27b", "qwen3.5:35b", "qwen2.5vl:7b",
    ]

    /// Phase 7.5 -- natural-language input assist. Only ever fires after
    /// the real parser has already rejected the player's exact input; see
    /// checkForParserMiss() below.
    @AppStorage("islandNLAssistEnabled") private var nlAssistEnabled = false
    @State private var lastPlayerCommand: String?
    @State private var translationAttempted = false
    /// Bumped on every manually-submitted command; a translation attempt
    /// captures the generation it started with and discards its result if
    /// the player has since moved on to something else, rather than
    /// executing a stale translated command out of order.
    @State private var commandGeneration = 0

    /// Phase 7.6 -- on-demand hints, rate-limited to one per
    /// `hintCooldownTurns` real turns (using transcript length as a cheap
    /// turn counter) so it stays a nudge rather than a crutch.
    @StateObject private var hints = HintService()
    @State private var showHintSheet = false
    @State private var lastHintTranscriptCount = -999
    private let hintCooldownTurns = 5
    private var hintOnCooldown: Bool {
        engine.transcript.count - lastHintTranscriptCount < hintCooldownTurns
    }

    var body: some View {
        Group {
            if let error = engine.launchError {
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
            } else {
                gameView
            }
        }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
        .onChange(of: engine.room) { _ in recordLore() }
        .onChange(of: engine.roomObjects) { _ in recordLore() }
        .onChange(of: narrationEnabled) { _ in recordLore() }
        .onChange(of: narrationModel) { _ in recordLore() }
        .onChange(of: engine.transcript.count) { _ in checkForParserMiss() }
        .sheet(isPresented: $showLore) {
            LoreView(store: lore)
        }
        .sheet(isPresented: $showHintSheet) {
            hintSheet
        }
    }

    /// Placeholder shown in place of the engine's raw reject text the
    /// instant a miss is detected (see checkForParserMiss below), so the
    /// player never reads "WHAT!" as the final answer only to have it
    /// silently rewrite itself a second or two later once the model
    /// responds -- that swap-after-the-fact read as a glitch (the engine
    /// feels instant; the LLM doesn't, and the mismatch was confusing).
    /// Styled like the existing "(trying: ...)" UI note rather than the
    /// engine's own ALL-CAPS voice, so it's unmistakably a "the game is
    /// thinking" aside, not a game-world line.
    private static let thinkingPlaceholder = "(thinking...)"

    /// Phase 7.5/7.7: if the player's last command produced one of the
    /// parser's own "didn't understand that" messages (not "understood
    /// but that's not here" -- see CommandTranslator.looksLikeParserMiss's
    /// doc comment), try translating their original free-text input into a
    /// valid two-word command and resend it automatically (7.5). If no
    /// real engine action matches either -- there's genuinely nothing in
    /// the game that responds to what they typed -- and Enriched
    /// narration is on, ask the model for a short in-world, non-committal
    /// reaction instead of leaving the engine's blunt reject text on
    /// screen (7.7), replacing that one transcript line in place rather
    /// than appending a new one. At most one attempt per player-submitted
    /// command either way, so a translated command that also misses just
    /// stops there instead of looping.
    private func checkForParserMiss() {
        guard nlAssistEnabled, !translationAttempted,
              let last = engine.transcript.last,
              let original = lastPlayerCommand,
              CommandTranslator.looksLikeParserMiss(last) else { return }
        translationAttempted = true
        let visibleIDs = Array(Set(engine.roomObjects + engine.inventory))
        let generation = commandGeneration
        // Captured now, before any async work: whatever ends up in this
        // slot is only ever applied if this is *still* the last
        // transcript entry when a result comes back. If anything else has
        // appended in the meantime, the replace is skipped so history
        // never gets rewritten out of order.
        let missIndex = engine.transcript.count - 1
        let originalRejectText = last
        engine.transcript[missIndex] = Self.thinkingPlaceholder

        Task {
            // Whatever happens below, leave this line looking sane: if
            // nothing ends up resolving it to something better, put the
            // engine's real text back rather than stranding the
            // "(thinking...)" placeholder forever. The extra equality
            // check is just a safety valve against clobbering something
            // else that might (in principle) have since been written to
            // this same slot.
            var resolved = false
            defer {
                if !resolved, engine.transcript.indices.contains(missIndex),
                   engine.transcript[missIndex] == Self.thinkingPlaceholder {
                    engine.transcript[missIndex] = originalRejectText
                }
            }

            if let translation = await CommandTranslator.translate(
                playerInput: original, visibleItemIDs: visibleIDs, model: narrationModel
            ), generation == commandGeneration {
                resolved = true
                engine.appendNote("(trying: \(translation.displayCommand))")
                engine.send(translation.engineCommand)
                return
            }

            // No real engine action matches this input either. In
            // Enriched mode, cover for the engine's blunt reject with a
            // short in-world reaction (7.7) instead of leaving "WHAT!" on
            // screen -- see ImprovService's doc comment for the safety
            // property this leans on (the engine has already decided
            // nothing happens; this only narrates that "nothing" more
            // gracefully, never decides anything itself). If the model
            // call fails, times out, or Enriched mode is off, the defer
            // above restores the engine's original text -- the agreed
            // fallback, not a bug.
            guard narrationEnabled, generation == commandGeneration else { return }
            let context = NarrationContext.assemble(
                room: engine.room,
                roomObjects: engine.roomObjects,
                recentTranscript: engine.transcript,
                time: engine.time,
                strength: engine.strength,
                wisdom: engine.wisdom,
                lore: lore,
                // Treat every story panel already unlocked as "already
                // known" so this reject-cover response never gets handed
                // a "the player just learned this" backstory beat -- that
                // framing belongs to real room narration (recordLore()),
                // not to a non-event like this one.
                previouslyUnlockedStoryPanelIDs: Set(lore.unlockedStory.map(\.panel))
            )
            if let reply = await ImprovService.respond(
                playerInput: original, context: context, model: narrationModel
            ), generation == commandGeneration, engine.transcript.count == missIndex + 1 {
                resolved = true
                engine.transcript[missIndex] = reply
            }
        }
    }

    private var hintSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A Hint").font(.title2.bold())
            if hints.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking...").foregroundStyle(.tertiary)
                }
            } else if let hint = hints.currentHint {
                Text(hint).fixedSize(horizontal: false, vertical: true)
            } else if let error = hints.lastError {
                Text(error).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Close") { showHintSheet = false }
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 180)
    }

    /// Feeds the current turn's state into LoreStore, then (if Enriched
    /// mode is on) kicks off narration for wherever the player ended up.
    /// Cheap/idempotent, so firing it on both room and roomObjects changes
    /// (they usually change together) is harmless -- see LoreStore.record
    /// and NarrationService.narrate's own guards.
    private func recordLore() {
        lore.record(room: engine.room, roomObjects: engine.roomObjects, inventory: engine.inventory)
        guard narrationEnabled, engine.room != 0 else { return }
        let context = NarrationContext.assemble(
            room: engine.room,
            roomObjects: engine.roomObjects,
            recentTranscript: engine.transcript,
            time: engine.time,
            strength: engine.strength,
            wisdom: engine.wisdom,
            lore: lore,
            previouslyUnlockedStoryPanelIDs: previousStoryPanelIDs
        )
        previousStoryPanelIDs = Set(lore.unlockedStory.map(\.panel))
        narration.narrate(context: context, model: narrationModel)
    }

    private var gameView: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            inventoryBar
            Divider()
            HSplitView {
                illustrationPanel
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
                transcriptPanel
                    .frame(minWidth: 320)
            }
            Divider()
            inputBar
        }
        .frame(minWidth: 820, minHeight: 672)
        .alert("Close Island of Secrets?", isPresented: $showCloseConfirmation) {
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
            statLabel("Food", "\(engine.food)")
            statLabel("Drink", "\(engine.drink)")
            Spacer()
            Button("Save") { engine.saveGame() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.isGameOver)
                .help("Save game (\u{2318}S)")
            Button("Load") { engine.loadGame() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.isGameOver)
                .help("Load game (\u{2318}L)")
            Button {
                showLore = true
            } label: {
                Label("Book", systemImage: "book.closed")
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("The story so far, and who you've met")
            Button {
                MapWindowController.shared.show(nextTo: NSApplication.shared.keyWindow)
            } label: {
                Label("Map", systemImage: "map")
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Grandpa's map in its own window")
            Toggle("Enriched", isOn: $narrationEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Add local-model narration alongside the classic text")
            if narrationEnabled {
                Picker("", selection: $narrationModel) {
                    ForEach(Self.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .frame(width: 140)
                .help("Ollama model used for narration")
            }
            Toggle("NL Assist", isOn: $nlAssistEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("If a command isn't understood, try translating free text into the two-word syntax")
            Button {
                requestHint()
            } label: {
                Label("Hint", systemImage: "lightbulb")
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.isGameOver || hintOnCooldown)
                .help(hintOnCooldown ? "Explore a bit more before asking again" : "Ask for a gentle nudge, grounded only in what you've seen so far")
            Button("Close") {
                if engine.isGameOver {
                    closeGame()
                } else {
                    showCloseConfirmation = true
                }
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help("Quit Island of Secrets (\u{2318}Q)")
            if engine.isGameOver {
                Text("GAME OVER")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func statLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var inventoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if engine.inventory.isEmpty {
                    Text("Carrying nothing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(engine.inventory, id: \.self) { itemID in
                        inventoryIcon(for: itemID)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(height: 68)
    }

    private func inventoryIcon(for itemID: Int) -> some View {
        VStack(spacing: 2) {
            Group {
                if let image = RoomArt.itemImage(for: itemID) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(ItemsData.name(for: itemID))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 56)
        }
        .help(ItemsData.name(for: itemID))
    }

    private var illustrationPanel: some View {
        VStack {
            if let image = RoomArt.roomImage(for: engine.room) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.12))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("No illustration yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    )
            }
            if let note = LoreData.places[engine.room] {
                Text(note)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            if narrationEnabled {
                narrationPanel
            }
        }
        .padding(12)
    }

    /// Phase 7.3's visible feature: the local model's expanded take on the
    /// current room, additive to (never replacing) the classic transcript
    /// text. Silently absent on error -- see NarrationService's own
    /// "never block gameplay" posture -- except a one-line note so the author
    /// knows why nothing showed up (e.g. Ollama isn't running).
    private var narrationPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if narration.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Narrating...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else if let text = narration.currentText, narration.currentRoomID == engine.room {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = narration.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 6)
    }

    private var transcriptPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(engine.transcript.enumerated()), id: \.offset) { index, entry in
                        Text(entry)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(16)
            }
            .onChange(of: engine.transcript.count) { _ in
                if let lastIndex = engine.transcript.indices.last {
                    withAnimation {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
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
        lastPlayerCommand = trimmed
        translationAttempted = false
        commandGeneration += 1
        engine.send(trimmed)
        commandText = ""
    }

    private func requestHint() {
        lastHintTranscriptCount = engine.transcript.count
        showHintSheet = true
        let context = NarrationContext.assemble(
            room: engine.room,
            roomObjects: engine.roomObjects,
            recentTranscript: engine.transcript,
            time: engine.time,
            strength: engine.strength,
            wisdom: engine.wisdom,
            lore: lore,
            previouslyUnlockedStoryPanelIDs: previousStoryPanelIDs
        )
        hints.requestHint(context: context, model: narrationModel)
    }
}
