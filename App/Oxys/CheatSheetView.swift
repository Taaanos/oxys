import Commands
import Library
import SwiftUI

/// The `?` overlay (M-23): the current mode's commands in the PRD's groups, with the keys of the current keymap,
/// printed the way the menus print them, on a dimmed backdrop. A click outside the panel, its own key (`?` at first) or `Esc` closes it;
/// the arrows, Page keys, Home, End and Space scroll it. It is not a window, so `CommandCenter` hands it the keys
/// (`AppModel.cheatSheetKey`) and swallows the rest.
struct CheatSheetView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let center = model.commands
        let sections = CheatSheet.sections(table: center.table, keymap: center.keymap, mode: center.mode)
        GlassEffectContainer {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { model.showCheatSheet = false }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts").font(.title3.bold())
                    Text(center.mode.rawValue.capitalized).foregroundStyle(.secondary)
                    Spacer()
                    let close = center.keyText("help.cheatsheet")
                    Text(close.isEmpty ? "Esc to close" : "\(close) or Esc to close").font(.callout).foregroundStyle(.secondary)
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
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
                .scrollPosition(Bindable(model).cheatScroll)
                .onScrollGeometryChange(for: [CGFloat].self) { g in
                    [g.contentOffset.y, g.containerSize.height, g.contentSize.height]
                } action: { _, v in
                    model.cheatMetrics = (v[0], v[1], v[2])
                }
            }
            .frame(maxWidth: 560, maxHeight: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .glassEffectTransition(reduceMotion ? .identity : .materialize)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        }
    }

    private func row(_ entry: CheatSection.Entry) -> some View {
        let keys = entry.shortcuts.map { KeyLabels.label(for: $0) }
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
}
