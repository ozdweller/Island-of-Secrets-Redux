import SwiftUI
import AppKit

/// "The book" -- an in-app codex of story panels and character bios,
/// unlocking as LoreStore observes the player actually encountering them.
/// Opened from a toolbar button (see ContentView.swift); needs no network
/// access and no LLM at all, since it's just revealing the Phase 7.0
/// transcription in the order the player earns it. See
/// docs/LLM_ENRICHMENT_PLAN.md Phase 7.4.
struct LoreView: View {
    @ObservedObject var store: LoreStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .story

    enum Tab: String, CaseIterable, Identifiable {
        case story = "Story so far"
        case characters = "Characters met"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("The Book")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                switch selectedTab {
                case .story:
                    storyTab
                case .characters:
                    charactersTab
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
    }

    private var storyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.unlockedStory.isEmpty {
                emptyState("The story hasn't begun to reveal itself yet. Keep exploring.")
            } else {
                ForEach(store.unlockedStory) { panel in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(panel.panel)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(panel.text)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if store.lockedStoryCount > 0 {
                    footerNote("\(store.lockedStoryCount) more chapter\(store.lockedStoryCount == 1 ? "" : "s") of the story remain untold.")
                }
            }
        }
        .padding(16)
    }

    private var charactersTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.metCharacters.isEmpty {
                emptyState("You haven't met anyone worth remembering yet.")
            } else {
                ForEach(store.metCharacters) { character in
                    HStack(alignment: .top, spacing: 12) {
                        portrait(for: character)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(character.name)
                                .font(.headline)
                            Text(character.bookCaption)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(character.storyRole)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                }
                if store.lockedCharacterCount > 0 {
                    footerNote("\(store.lockedCharacterCount) more character\(store.lockedCharacterCount == 1 ? "" : "s") await, somewhere on the island.")
                }
            }
        }
        .padding(16)
    }

    private func portrait(for character: LoreCharacter) -> some View {
        Group {
            if let data = LoreData.portraitImage(for: character), let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.fill.questionmark")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 56, height: 56)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    private func footerNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .italic()
            .padding(.top, 8)
    }
}
