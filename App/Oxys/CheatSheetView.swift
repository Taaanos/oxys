import Commands
import Library
import SwiftUI

/// The `?` sheet (M-23): the current mode's commands in the PRD's groups, with the keys of the current keymap,
/// printed the way the menus print them. `?` or `Esc` closes it; the list scrolls with the arrow, Page and
/// Home/End keys. It is a sheet, so the command key monitor leaves its keys alone.
struct CheatSheetView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        let center = model.commands
        let sections = CheatSheet.sections(table: center.table, keymap: center.keymap, mode: center.mode)
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title3.bold())
                Text(center.mode.rawValue.capitalized).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    ForEach(sections, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.group.title).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(section.entries) { entry in row(entry) }
                        }
                    }
                    if !center.keymapProblems.isEmpty {
                        Text("Some of your Keymap.json was ignored; see Console for details.").foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focused($focused)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 620)
        .onAppear { focused = true }
        .onKeyPress(characters: ["?"]) { _ in dismiss(); return .handled }
    }

    private func row(_ entry: CheatSection.Entry) -> some View {
        let keys = entry.shortcuts.map(Self.label)
        return HStack(alignment: .firstTextBaseline) {
            Text(entry.title)
            Spacer()
            Text(keys.isEmpty ? "—" : keys.joined(separator: "   "))
                .font(.body.monospaced()).foregroundStyle(keys.isEmpty ? .tertiary : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(keys.isEmpty ? "no key" : keys.joined(separator: ", or "))
    }

    private static func label(_ shortcut: Shortcut) -> String {
        KeyLabels.label(for: shortcut.modifiers) + KeyLabels.label(for: shortcut.key)
    }
}
