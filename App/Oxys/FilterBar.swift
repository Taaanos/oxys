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

    private static let swatches: [ColorLabel: Color] = [
        .red: .red, .yellow: .yellow, .green: .green, .blue: .blue, .purple: .purple,
    ]

    var body: some View {
        let filter = model.folder.filter
        HStack(spacing: 14) {
            Toggle("Filter", isOn: Binding(get: { filter.isOn }, set: { _ in model.commands.perform("filter.enabled") }))
                .toggleStyle(.switch).controlSize(.mini)
                .help("Filtering on or off (⌘L)")
            stars(filter)
            labels(filter)
            Picker("Rejects", selection: Binding(
                get: { filter.rejects }, set: { new in model.setFilter { $0.rejects = new } })) {
                ForEach(RejectFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Rejected photos (⌥⌘X cycles)")
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
                .accessibilityLabel("Find by filename")
            Button("Clear", systemImage: "xmark.circle") { model.commands.perform("filter.clear") }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!filter.hasCriteria)
                .help("Clear the filter")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .opacity(filter.isOn ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter and sort")
        .onChange(of: model.findRequest) { searchFocused = true }
        .onAppear { if model.findRequest > 0 { searchFocused = true } }
    }

    private func stars(_ filter: PhotoFilter) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                let lit = n <= filter.minStars
                Button {
                    // A second click on the lit minimum clears it.
                    model.setFilter { $0.minStars = $0.minStars == n ? 0 : n }
                } label: {
                    Image(systemName: lit ? "star.fill" : "star").foregroundStyle(lit ? Color.yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(n == 5 ? "5 stars (⌥⌘5)" : "\(n) stars or more (⌥⌘\(n))")
                .accessibilityLabel(n == 1 ? "1 star or more" : n == 5 ? "5 stars" : "\(n) stars or more")
                .accessibilityAddTraits(filter.minStars == n ? .isSelected : [])
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
