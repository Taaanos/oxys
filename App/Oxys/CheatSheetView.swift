import Commands
import Library
import SwiftUI

/// The `⌘K` Command Bar (M-23): merges shortcut discovery and command execution for the current mode.
/// Empty query shows the mode's commands grouped by category with their current keymap labels; typing
/// switches to a flat, ranked search list. Disabled commands remain visible (dimmed and non-selectable)
/// so their shortcuts stay discoverable. `↑`/`↓` move across enabled items, `↵` runs `.perform`,
/// and `Esc`, `⌘K`, or a click outside dismisses the bar and restores focus to the canvas.
struct CheatSheetView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var contentHeight: CGFloat = 440

    var body: some View {
        let center = model.commands
        let sections = model.cheatSections
        let isSearching = !model.cheatSearch.trimmingCharacters(in: .whitespaces).isEmpty
        let searchResults = isSearching ? CheatSheet.search(sections: sections, query: model.cheatSearch) : []

        GlassEffectContainer {
            ZStack(alignment: .top) {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeCheatSheet() }
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    searchHeader(center: center)
                    Divider()
                    resultsBody(
                        sections: sections,
                        isSearching: isSearching,
                        searchResults: searchResults,
                        keymapProblems: center.keymapProblems
                    )
                }
                .frame(width: 540)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
                .padding(.top, 84)
                .padding(.horizontal, 24)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
        }
        .onAppear {
            searchFocused = true
        }
        .onChange(of: model.cheatSearch) {
            let entries = isSearching
                ? CheatSheet.search(sections: model.cheatSections, query: model.cheatSearch)
                : model.cheatSections.flatMap(\.entries)
            model.cheatSelectedID = entries.first(where: \.isEnabled)?.id
        }
    }

    private func searchHeader(center: CommandCenter) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Type a command or search shortcuts…", text: Bindable(model).cheatSearch)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityLabel("Type a command or search shortcuts")
            Text(center.mode.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Text("Esc")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func resultsBody(
        sections: [CheatSection],
        isSearching: Bool,
        searchResults: [CheatSection.Entry],
        keymapProblems: [String]
    ) -> some View {
        if isSearching && searchResults.isEmpty {
            ContentUnavailableView.search(text: model.cheatSearch)
                .frame(height: 160)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: isSearching ? 2 : 14) {
                        if isSearching {
                            ForEach(searchResults) { entry in
                                row(entry, showGroup: true)
                            }
                        } else {
                            ForEach(sections, id: \.group) { section in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.group.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 2)
                                        .padding(.bottom, 2)
                                        .accessibilityAddTraits(.isHeader)
                                    ForEach(section.entries) { entry in
                                        row(entry, showGroup: false)
                                    }
                                }
                            }
                            if !keymapProblems.isEmpty {
                                Text("Some of your Keymap.json was ignored; see Console for details.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, 44), 440))
                .onChange(of: model.cheatSelectedID) { _, newID in
                    guard let newID else { return }
                    proxy.scrollTo(newID)
                }
            }
        }
    }

    private func row(_ entry: CheatSection.Entry, showGroup: Bool) -> some View {
        let keys = entry.shortcuts.map { KeyLabels.label(for: $0) }
        let isSelected = entry.isEnabled && entry.id == model.cheatSelectedID
        return HStack(spacing: 8) {
            Group {
                if let symbol = entry.symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 18, height: 18)

            Text(entry.title)
                .lineLimit(1)

            if showGroup {
                Text(entry.group.title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if entry.isOn {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(keys.isEmpty ? "—" : keys.joined(separator: "   "))
                .font(.body.monospaced())
                .foregroundStyle(keys.isEmpty ? .tertiary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(entry.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isEnabled { model.runCheatCommand(entry.id) }
        }
        .id(entry.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isEnabled ? entry.title : "\(entry.title), unavailable")
        .accessibilityValue(keys.isEmpty ? "no key" : keys.joined(separator: ", or "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
