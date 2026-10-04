import AppKit
import Commands
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The state of Settings → Keys (V-14): which key is being recorded, and what the row that was edited says.
/// Recording works through the command center's `keyCapture` hook. That hook sits in front of the menus and the
/// responder chain, so `⌘` chords, `Esc` and bare letters all reach `captured(_:)`, and none of them runs a command.
@MainActor @Observable
final class KeysModel {
    struct Target: Equatable {
        var command: CommandID
        /// The key a new one takes the place of; nil adds a key.
        var replacing: Shortcut?
    }

    /// A key that clashes with another command's, waiting for the user to say "Reassign" or cancel.
    struct Pending {
        var shortcut: Shortcut
        var target: Target
    }

    struct Notice {
        var command: CommandID
        var text: String
        var pending: Pending?
    }

    let store: KeymapStore
    let center: CommandCenter
    private(set) var recording: Target?
    private(set) var notice: Notice?
    /// What the search field holds; the list shows the commands that match every word.
    var search = ""
    @ObservationIgnored private var observers: [Any] = []

    init(store: KeymapStore, center: CommandCenter) {
        self.store = store
        self.center = center
    }

    func startRecording(_ target: Target) {
        stopRecording()
        notice = nil
        recording = target
        center.keyCapture = { [weak self] input in self?.captured(input) }
        // A key press the window never sees (another window, another app) must not leave the keyboard captured.
        let names: [Notification.Name] = [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            }
        }
    }

    func stopRecording() {
        recording = nil
        center.keyCapture = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    func dismissNotice() { notice = nil }

    private func captured(_ input: KeyInput) {
        guard let target = recording else { return }
        switch Shortcut.capture(input) {
        case .cancel:
            stopRecording()
            notice = nil
        case .unsupported:
            notice = Notice(command: target.command, text: "Oxys cannot use this key. Press another key.")
        case .shortcut(let shortcut):
            attempt(shortcut, target: target, reassign: false)
        }
    }

    func reassign() {
        guard let pending = notice?.pending else { return }
        attempt(pending.shortcut, target: pending.target, reassign: true)
    }

    private func attempt(_ shortcut: Shortcut, target: Target, reassign: Bool) {
        // Nil: the file is blocked or could not be written. The banner above the list says why.
        guard let result = store.assign(shortcut, to: target.command, replacing: target.replacing, reassign: reassign) else {
            stopRecording()
            return
        }
        let key = KeyLabels.label(for: shortcut)
        let name = center.table[target.command]?.title ?? target.command.rawValue
        switch result {
        case .ok:
            stopRecording()
            notice = nil
        case .duplicate:
            notice = Notice(command: target.command, text: "\(name) already has \(key). Press another key.")
        case .reserved(let reason):
            notice = Notice(command: target.command, text: "\(reason) Press another key.")
        case .conflicts(let list):
            let owners = list.map { "\($0.title) (\(Self.modesText($0.modes)))" }.formatted(.list(type: .and))
            if let twin = list.first(where: \.isShiftTwin) {
                // The twin is made from the other command's own key. Only that key can free it.
                notice = Notice(command: target.command, text: "\(key) is the apply-and-move key of \(twin.title). Change its own key first, or press another key.")
            } else {
                stopRecording()
                notice = Notice(command: target.command, text: "\(key) already runs \(owners).",
                                pending: Pending(shortcut: shortcut, target: target))
            }
        }
    }

    /// "Grid, Loupe" for a command that works in some modes; nil for one that works in all.
    static func limitedModesText(_ modes: Set<ViewMode>) -> String? {
        modes.isEmpty || modes.count == ViewMode.allCases.count ? nil : modesText(modes)
    }

    /// "Grid, Loupe", or "every mode".
    static func modesText(_ modes: Set<ViewMode>) -> String {
        if modes.isEmpty || modes.count == ViewMode.allCases.count { return "every mode" }
        return ViewMode.allCases.filter(modes.contains).map { $0.rawValue.capitalized }.formatted(.list(type: .and))
    }
}

/// Settings → Keys: every command with its keys. Press `+` to add a key, a key to change or remove it. A key that
/// another command has in the same modes is offered for reassignment before anything is saved.
struct KeysPane: View {
    @Bindable var keys: KeysModel
    @State private var askResetAll = false
    @State private var importRequest: ImportRequest?
    @State private var importError: String?

    private struct ImportRequest {
        var name: String
        var preview: KeymapStore.ImportPreview
    }

    init(model: AppModel) { keys = model.keysModel }

    var body: some View {
        let store = keys.store
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search commands and keys", text: $keys.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search commands and keys")
                fileMenu
            }
            banner(store)
            let groups = visibleGroups
            if groups.isEmpty {
                ContentUnavailableView.search(text: keys.search)
            } else {
                List {
                    ForEach(groups, id: \.group) { section in
                        Section {
                            ForEach(section.commands) { command in
                                KeyRow(command: command, keys: keys)
                            }
                        } header: {
                            Text(section.group.title).accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .listStyle(.inset)
                // With a file Oxys cannot read, nothing here writes: Start Over comes first.
                .disabled(store.isBlocked)
            }
        }
        .frame(height: 440)
        .onDisappear { keys.stopRecording() }
        .alert("Import \(importRequest?.name ?? "keys")?", isPresented: Binding(get: { importRequest != nil }, set: { if !$0 { importRequest = nil } }),
               presenting: importRequest) { request in
            Button("Import") { store.commitImport(request.preview) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(importMessage(request, current: store.editor.customizedCount))
        }
        .alert("The file cannot be imported", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog("Reset all keys?", isPresented: $askResetAll) {
            Button("Reset All", role: .destructive) { store.resetAll() }
        } message: {
            Text("\(store.editor.customizedCount.formatted()) changed commands go back to the Default keys. Export the keys first to keep them.")
        }
    }

    // MARK: pieces

    private var fileMenu: some View {
        let store = keys.store
        return Menu {
            Button("Import…") { chooseImport() }
                .disabled(store.isBlocked)
            Button("Export…") { chooseExport() }
                .disabled(store.isBlocked)
            Button("Show File in Finder") { store.revealInFinder() }
            Divider()
            Button("Reset All…", role: .destructive) { askResetAll = true }
                .disabled(store.editor.customizedCount == 0 || store.isBlocked)
        } label: {
            Label("Keymap file", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Keymap file")
    }

    /// What is wrong with the file, or with the last save. Nothing shows when all is well.
    @ViewBuilder private func banner(_ store: KeymapStore) -> some View {
        if case .blocked(let reason) = store.state {
            VStack(alignment: .leading, spacing: 6) {
                Label("Oxys cannot use Keymap.json, so the Default keys are on.", systemImage: "exclamationmark.triangle")
                    .font(.callout.bold())
                Text(reason).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Show File in Finder") { store.revealInFinder() }
                    Button("Start Over") { store.startOver() }
                        .help("Moves the file to Keymap.json.bak and uses the Default keys")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        } else if let error = store.writeError {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout)
        } else if !store.problems.isEmpty {
            DisclosureGroup {
                ForEach(store.problems, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            } label: {
                Label("Oxys ignored \(store.problems.count.formatted()) \(store.problems.count == 1 ? "entry" : "entries") of Keymap.json.",
                      systemImage: "exclamationmark.triangle").font(.callout)
            }
        }
    }

    private var visibleGroups: [(group: CheatGroup, commands: [Command])] {
        let center = keys.center
        let words = keys.search.split(separator: " ").map(String.init)
        func matches(_ command: Command) -> Bool {
            if words.isEmpty { return true }
            let haystack = [command.title, KeysModel.modesText(command.modes), center.keyText(command.id)]
                + keys.store.editor.shortcuts(for: command.id).map { KeyLabels.label(for: $0) }
            return words.allSatisfy { word in haystack.contains { $0.localizedCaseInsensitiveContains(word) } }
        }
        return CheatGroup.allCases.compactMap { group in
            let commands = center.table.commands.filter { $0.cheatGroup == group && matches($0) }
            return commands.isEmpty ? nil : (group, commands)
        }
    }

    private func importMessage(_ request: ImportRequest, current: Int) -> String {
        var lines = [current == 0 ? "The keys in the file are used from now on."
                                  : "This replaces your \(current.formatted()) changed commands with the keys in the file."]
        if !request.preview.problems.isEmpty {
            lines.append("Oxys will ignore \(request.preview.problems.count.formatted()) \(request.preview.problems.count == 1 ? "entry" : "entries"):")
            lines += request.preview.problems.prefix(5)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: files

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a keymap file."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                switch keys.store.previewImport(from: url) {
                case .success(let preview): importRequest = ImportRequest(name: url.lastPathComponent, preview: preview)
                case .failure(let error): importError = error.message
                }
            }
        }
    }

    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Oxys Keymap.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do { try keys.store.export(to: url) } catch { importError = "The keys could not be exported: \(error.localizedDescription)" }
            }
        }
    }
}

/// One command: its title and modes, one control per key, and a `+` to add a key.
private struct KeyRow: View {
    let command: Command
    let keys: KeysModel

    var body: some View {
        let store = keys.store
        let shortcuts = store.editor.shortcuts(for: command.id)
        let customized = store.editor.isCustomized(command.id)
        let recording = keys.recording?.command == command.id ? keys.recording : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title).lineLimit(1)
                    // Only a command that works in some modes says which; "every mode" under 80 rows would be noise.
                    if let modes = KeysModel.limitedModesText(command.modes) {
                        Text(modes).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if shortcuts.isEmpty, recording == nil {
                    Text("No key").foregroundStyle(.tertiary)
                }
                ForEach(shortcuts, id: \.self) { shortcut in
                    if recording?.replacing == shortcut {
                        waiting
                    } else {
                        keyMenu(shortcut)
                    }
                }
                if recording != nil, recording?.replacing == nil { waiting }
                Button { keys.startRecording(.init(command: command.id, replacing: nil)) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a key")
                .accessibilityLabel("Add a key for \(command.title)")
                if customized {
                    Button { store.reset(command.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Back to the Default keys")
                        .accessibilityLabel("Reset the keys of \(command.title)")
                }
            }
            if recording != nil {
                Text("Press the new key. Esc cancels.").font(.caption).foregroundStyle(.tint)
            }
            if let notice = keys.notice, notice.command == command.id {
                noticeView(notice)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(command.title)
        .accessibilityValue(customized ? "Changed" : "")
    }

    private var waiting: some View {
        Text("Press a key…")
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 1.5))
    }

    private func keyMenu(_ shortcut: Shortcut) -> some View {
        let label = KeyLabels.label(for: shortcut)
        return Menu {
            Button("Change Key…") { keys.startRecording(.init(command: command.id, replacing: shortcut)) }
            Button("Remove Key", role: .destructive) { keys.store.remove(shortcut, from: command.id) }
        } label: {
            Text(label).font(.body.monospaced())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(command.title), key \(label)")
        .accessibilityHint("Opens a menu to change or remove the key")
    }

    private func noticeView(_ notice: KeysModel.Notice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(notice.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if notice.pending != nil {
                HStack {
                    Button("Reassign") { keys.reassign() }
                    Button("Cancel") { keys.dismissNotice() }
                }
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
