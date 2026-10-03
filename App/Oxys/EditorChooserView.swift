import Library
import SwiftUI

/// `⌥⌘E`: a small list of editors on a dimmed backdrop. `↑` `↓` move, `⏎` opens the selection in the highlighted one,
/// `1` to `9` pick one, `Esc` or a click outside closes it. Missing editors are listed, dimmed, and skipped.
/// Like the cheat sheet it is not a window; `AppModel.editorChooserKey` gets the keys.
struct EditorChooserView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let editors = model.editors.editors
        GlassEffectContainer {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { model.showEditorChooser = false }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit In").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(Array(editors.enumerated()), id: \.element.id) { index, editor in
                    let installed = model.editors.isInstalled(editor)
                    HStack {
                        Text(index < 9 ? "\(index + 1)" : "").foregroundStyle(.secondary).frame(width: 16)
                        Text(editor.name)
                        if editor.id == model.editors.defaultEditor?.id { Text("default").foregroundStyle(.secondary) }
                        Spacer()
                        if !installed { Text("not installed").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(index == model.editorChooserIndex ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .opacity(installed ? 1 : 0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { model.chooseEditor(at: index) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(installed ? editor.name : "\(editor.name), not installed")
                    .accessibilityAddTraits(index == model.editorChooserIndex ? .isSelected : [])
                }
                Text("↑ ↓ and Return, or a number. Esc closes.").font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            }
            .padding(16)
            .frame(width: 340)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .glassEffectTransition(reduceMotion ? .identity : .materialize)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        }
    }
}
