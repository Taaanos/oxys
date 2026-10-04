import AppKit
import Commands
import Library
import SwiftUI

/// The filter and sort bar (M-20), shown with `\`. Everything on it is also a command in the Filter menu with a
/// key, so the bar is for the pointer and for seeing the state; `⌘F` puts the keyboard in the search field and
/// `Esc` takes it back to the image.
struct FilterBar: View {
    let model: AppModel
    @FocusState private var searchFocused: Bool
    /// The last `⌘F` this bar acted on, so showing the bar later does not count as a new request.
    @State private var handledFind = 0

    private static let swatches: [ColorLabel: Color] = [
        .red: .red, .yellow: .yellow, .green: .green, .blue: .blue, .purple: .purple,
    ]

    var body: some View {
        let filter = model.folder.filter
        HStack(spacing: 14) {
            Toggle("Filter", isOn: Binding(get: { filter.isOn }, set: { _ in model.commands.perform("filter.enabled") }))
                .toggleStyle(.switch).controlSize(.mini)
                .help("Filtering on or off\(model.commands.hint("filter.enabled"))")
            stars(filter)
            labels(filter)
            Picker("Rejects", selection: Binding(
                get: { filter.rejects }, set: { new in model.setFilter { $0.rejects = new } })) {
                ForEach(RejectFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Rejected photos\(model.commands.keyText("filter.rejects.cycle").isEmpty ? "" : " (\(model.commands.keyText("filter.rejects.cycle")) cycles)")")
            .accessibilityLabel("Rejected photos")
            Spacer(minLength: 8)
            sort(filter)
            TextField("Find by filename", text: Binding(
                get: { filter.search },
                set: { new in model.folder.updateFilter { $0.search = new; $0.isOn = true } }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .focused($searchFocused)
                .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
                // `\` is the bar's own key, as in Finder: with the field focused it hides the bar instead of typing a backslash.
                .onKeyPress(characters: CharacterSet(charactersIn: "\\"), phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    model.commands.perform("filter.bar")
                    return .handled
                }
                .accessibilityLabel("Find by filename")
            Button("Clear", systemImage: "xmark.circle") { model.commands.perform("filter.clear") }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!filter.hasCriteria)
                .help("Clear the filter")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(filter.isOn ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter and sort")
        .onChange(of: model.findRequest) { handledFind = model.findRequest; searchFocused = true }
        .onAppear {
            if model.findRequest != handledFind {
                handledFind = model.findRequest
                searchFocused = true
            } else {
                // AppKit hands a new bar's first text field the keyboard; the keys belong to the photo unless ⌘F asked.
                DispatchQueue.main.async { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
    }

    private func stars(_ filter: PhotoFilter) -> some View {
        HStack(spacing: 2) {
            let noStars = filter.stars.contains(0)
            Button {
                let flags = NSEvent.modifierFlags
                model.setFilter { $0.clickStar(0, extend: flags.contains(.shift), toggle: flags.contains(.command)) }
            } label: {
                Image(systemName: "star.slash").foregroundStyle(noStars ? Color.yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help("No stars. ⌘-click to add it to other ratings\(model.commands.hint("filter.stars.unrated"))")
            .accessibilityLabel("No stars")
            .accessibilityAddTraits(noStars ? .isSelected : [])
            ForEach(1...5, id: \.self) { n in
                let lit = filter.stars.contains(n)
                Button {
                    // A click is that star alone; ⌘-click adds or removes one (1 and 3); ⇧-click makes a range (2, then ⇧5, is 2 to 5); ⌥-click is "or more".
                    let flags = NSEvent.modifierFlags
                    model.setFilter { $0.clickStar(n, extend: flags.contains(.shift), toggle: flags.contains(.command),
                                                   orMore: flags.contains(.option)) }
                } label: {
                    Image(systemName: lit ? "star.fill" : "star").foregroundStyle(lit ? Color.yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help("\(n == 1 ? "1 star" : "\(n) stars"). ⌘-click to add another, ⇧-click for a range, ⌥-click for \(n) or more\(model.commands.hint(CommandID(rawValue: "filter.stars.\(n)")))")
                .accessibilityLabel(n == 1 ? "1 star" : "\(n) stars")
                .accessibilityAddTraits(lit ? .isSelected : [])
            }
        }
    }

    private func labels(_ filter: PhotoFilter) -> some View {
        HStack(spacing: 6) {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                let on = filter.labels.contains(label)
                let color = Self.swatches[label] ?? .gray
                Button {
                    model.setFilter { if !$0.labels.insert(label).inserted { $0.labels.remove(label) } }
                } label: {
                    Circle().strokeBorder(color, lineWidth: 2)
                        .background(Circle().fill(on ? color : .clear))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .help("\(label.name) label")
                .accessibilityLabel("\(label.name) label")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            // Gray is "no label", as in the select-by popover.
            Button {
                model.setFilter { $0.noLabel.toggle() }
            } label: {
                Circle().strokeBorder(Color.gray, lineWidth: 2)
                    .background(Circle().fill(filter.noLabel ? Color.gray : .clear))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .help("No label\(model.commands.hint("filter.label.none"))")
            .accessibilityLabel("No label")
            .accessibilityAddTraits(filter.noLabel ? .isSelected : [])
        }
    }

    private func sort(_ filter: PhotoFilter) -> some View {
        HStack(spacing: 4) {
            Picker("Sort", selection: Binding(
                get: { filter.sortKey }, set: { new in model.setFilter { $0.sortKey = new } })) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel("Sort by")
            Button(filter.ascending ? "Ascending" : "Descending",
                   systemImage: filter.ascending ? "arrow.up" : "arrow.down") {
                model.setFilter { $0.ascending.toggle() }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .help("Sort order")
        }
    }
}
