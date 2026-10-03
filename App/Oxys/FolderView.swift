import AppKit
import Commands
import Library
import SwiftUI

/// The window's content: the empty state until a folder is open, then the folder.
/// An opened folder lands in Grid; Return, Space or a double-click opens the active photo in Loupe.
struct FolderView: View {
    let model: AppModel

    var body: some View {
        let folder = model.folder
        Group {
            switch folder.content {
            case .none:
                EmptyStateView(message: EmptyStateNSView.message)
            case .opening:
                EmptyStateView(message: "Opening…")
            case .empty(let hasSubfolderPhotos):
                EmptyStateView(message: hasSubfolderPhotos
                               ? "No photos in this folder, but its subfolders have some. Open one of them."
                               : "No photos in this folder.")
            case .failed(let reason):
                EmptyStateView(message: "Couldn't open this folder: \(reason)")
            case .photos:
                let mode = model.commands.mode
                let loupeActive = mode == .loupe
                VStack(spacing: 0) {
                    if model.showFilterBar { FilterBar(model: model) }
                    ZStack {
                        LoupeScreen(model: model, active: loupeActive)
                            .opacity(loupeActive ? 1 : 0)
                            .allowsHitTesting(loupeActive)
                            .accessibilityHidden(!loupeActive)
                        if mode == .compare { CompareScreen(model: model) }
                        if mode == .grid { GridScreen(controller: model.grid) }
                    }
                    // With the chrome hidden the photo reclaims the titlebar strip; an open filter bar keeps it.
                    .ignoresSafeArea(.container, edges: model.chromeHidden && !model.showFilterBar ? .top : [])
                }
            }
        }
        .overlay(alignment: .top) {
            if let banner = folder.banner {
                WriteBanner(banner: banner, unsaved: folder.unsavedCount, model: model)
            }
        }
        .inspector(isPresented: Binding(
            get: { model.showInspector && !model.chromeHidden },
            set: { if !model.chromeHidden { model.setInspector($0) } })) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.autoAdvance, folder.content == .photos, model.commands.mode == .grid {
                AutoAdvanceBadge().padding(.horizontal, 12).padding(.bottom, 4).allowsHitTesting(false)
            }
        }
        .overlay { if model.showCheatSheet { CheatSheetView(model: model) } }
        .overlay { if model.showEditorChooser { EditorChooserView(model: model) } }
        .overlay(alignment: .bottomLeading) { if model.extract.isShowing { ExtractPlate(job: model.extract) } }
        .toolbar(id: "oxys.main") { ToolbarItems(model: model) }
        .toolbarVisibility(model.chromeHidden ? .hidden : .visible, for: .windowToolbar)
        .background(WindowToolbarCollapser(hidden: model.chromeHidden))
        .navigationTitle(folder.folder?.lastPathComponent ?? "Oxys")
        .navigationSubtitle(Self.subtitle(folder))
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in model.handleDrop(urls) }
    }

    static func subtitle(_ folder: FolderModel) -> String {
        guard case .photos = folder.content else { return "" }
        let total = folder.photos.count
        let count = folder.filter.isNarrowing ? folder.visible.count : total
        let photos = count < total ? "\(count.formatted()) of \(total.formatted()) shown"
            : total == 1 ? "1 photo" : "\(total.formatted()) photos"
        let selected = folder.selection.count
        let head = selected > 0 ? "\(photos) · \(selected.formatted()) selected" : photos
        let new = folder.newFileCount
        guard new > 0 else { return head }
        return "\(head) · \(new == 1 ? "1 new file" : "\(new) new files"), reload with ⌥⌘R"
    }
}

/// The toolbar (M-13): a mode picker, the inspector toggle and a filter placeholder (M-20). Customizable from the
/// toolbar's context menu; every item is also a command in the menu bar.
private struct ToolbarItems: CustomizableToolbarContent {
    let model: AppModel

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "mode") {
            Picker("Mode", selection: Binding(
                get: { model.commands.mode },
                set: { mode in
                    guard mode != model.commands.mode else { return }
                    let command: CommandID = switch mode {
                    case .grid: "view.grid"
                    case .loupe: "view.loupe"
                    case .compare: "compare.enter"
                    }
                    model.commands.perform(command)
                })) {
                Text("Grid").tag(ViewMode.grid)
                Text("Loupe").tag(ViewMode.loupe)
                Text("Compare").tag(ViewMode.compare)
            }
            .pickerStyle(.segmented)
            .help("Grid (G), Loupe (E) or Compare (C)")
            .accessibilityLabel("View mode")
            .disabled(model.folder.content != .photos)
        }
        ToolbarItem(id: "filter") {
            Button("Filter Bar", systemImage: model.folder.filter.isNarrowing
                   ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                model.commands.perform("filter.bar")
            }
            .help("Filter bar (\\)")
            .accessibilityValue(model.showFilterBar ? "Shown" : "Hidden")
            .disabled(model.folder.content != .photos)
        }
        ToolbarItem(id: "inspector") {
            Button("Inspector", systemImage: "sidebar.trailing") { model.commands.perform("info.inspector") }
                .help("Inspector (⌥⌘I)")
                .accessibilityValue(model.showInspector ? "Shown" : "Hidden")
                .disabled(model.folder.content != .photos)
        }
    }
}

/// The non-modal notice for a read-only folder or a failed write. It never takes focus and never blocks a key.
private struct WriteBanner: View {
    let banner: FolderModel.Banner
    let unsaved: Int
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(message).lineLimit(2)
            Spacer(minLength: 8)
            if case .writeFailed = banner {
                Button("Retry") { model.folder.retryUnsaved() }
            }
            if showsSave {
                Button("Save Decisions To…") { Task { await model.saveDecisionsElsewhere() } }
            }
            Button("Dismiss") { model.folder.dismissBanner() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .onAppear { announce() }
        .onChange(of: message) { announce() }
    }

    private var showsSave: Bool {
        if case .savedCopy = banner { return false }
        return true
    }

    private var icon: String {
        if case .savedCopy = banner { "checkmark.circle" } else { "exclamationmark.triangle.fill" }
    }

    private var message: String {
        switch banner {
        case .readOnly:
            "This folder is read-only. Your decisions are kept in memory; save them to another folder, then move the .xmp files next to the photos."
        case .writeFailed(let reason):
            "\(unsaved == 1 ? "1 decision is" : "\(unsaved) decisions are") not saved: \(reason). They are kept in memory."
        case .savedCopy(let folder, let count):
            "Saved \(count == 1 ? "1 sidecar" : "\(count) sidecars") to \(folder.lastPathComponent). Move them next to the photos to reunite them."
        }
    }

    private func announce() {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// Collapses the window's toolbar strip itself. `.toolbarVisibility(.hidden)` hides the items, but in full screen AppKit
/// keeps the strip's height reserved, so the photo would sit under an empty band instead of reclaiming it.
private struct WindowToolbarCollapser: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let toolbar = view?.window?.toolbar else { return }
            toolbar.isVisible = !hidden
        }
    }
}
