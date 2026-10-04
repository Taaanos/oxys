import AppKit
import Canvas
import Imaging
import Library
import UniformTypeIdentifiers
import Sidecar
import SwiftUI

/// The Settings window (`⌘,`, M-22). Panes arrive with their features; the MVP has General and Sidecars.
/// Values live in user defaults and apply at once; the keymap keeps its own file (M-05).
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            RawPane().tabItem { Label("RAW", systemImage: "camera.aperture") }
            MemoryPane().tabItem { Label("Memory", systemImage: "memorychip") }
            EditorsPane(store: model.editors).tabItem { Label("Editors", systemImage: "square.and.pencil") }
            PeakingPane().tabItem { Label("Peaking", systemImage: "scope") }
            ClippingPane().tabItem { Label("Clipping", systemImage: "circle.lefthalf.filled") }
            SidecarsPane().tabItem { Label("Sidecars", systemImage: "doc.text") }
        }
        .frame(width: 500)
        .scenePadding()
    }
}

private struct GeneralPane: View {
    @AppStorage("autoAdvance") private var autoAdvance = false
    @AppStorage("pairRawJpeg") private var pairRawJpeg = true
    @AppStorage("reopenLastFolder") private var reopenLastFolder = true

    var body: some View {
        Form {
            Toggle("Reopen the last folder at launch", isOn: $reopenLastFolder)
            note("Each folder remembers its photo, filter, sort and selection, and any decision that could not be saved.")
            Toggle("Advance after rating, label or reject", isOn: $autoAdvance)
            note("Hold ⇧ with a key to apply it and stay on the photo. The A key switches this on and off.")
            Toggle("Show a RAW and its JPEG as one photo", isOn: $pairRawJpeg)
            note("A rating goes to both files. Switching this changes the open folder at once.")
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

private struct RawPane: View {
    @AppStorage("rawMode") private var rawMode = RawMode.default.rawValue
    @AppStorage("rawAutoActual") private var rawAutoActual = true

    var body: some View {
        Form {
            Picker("RAW decode", selection: $rawMode) {
                ForEach(RawMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            note("Never shows previews only. On demand decodes with R. Always decodes every RAW. ⇧R switches to Always until you quit.")
            Toggle("Automatic RAW at 1:1", isOn: $rawAutoActual)
                .disabled(rawMode == RawMode.never.rawValue)
            note("In On demand mode, 1:1 decodes the RAW when the preview has fewer pixels than the sensor.")
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

/// Settings → Memory: the two cache limits. Each stores 0 for Automatic.
private struct MemoryPane: View {
    @AppStorage("prefetchBudgetMB") private var budgetMB = 0
    @AppStorage("rawCacheCount") private var rawCount = 0
    /// What the slider shows while Automatic is on, and what returns when Custom is chosen.
    @State private var manualMB = 2048
    @State private var manualRawCount = LoupeController.automaticRawCount
    /// Bytes in the thumbnail cache; nil until the first measurement (V-23).
    @State private var thumbnailBytes: Int?

    private static let step = 256
    private static let automaticMB = LoupeController.automaticBudget >> 20
    private static let maxMB = max(1024, Int(ProcessInfo.processInfo.physicalMemory >> 20))
    private static let maxRawCount = 1000

    private var isBudgetAutomatic: Binding<Bool> {
        Binding(get: { budgetMB == 0 }, set: { budgetMB = $0 ? 0 : manualMB })
    }

    private var megabytes: Binding<Int> {
        Binding(get: { budgetMB == 0 ? Self.automaticMB : budgetMB },
                set: { value in
                    let clamped = min(max(value, Self.step), Self.maxMB)
                    manualMB = clamped
                    if budgetMB != 0 { budgetMB = clamped }
                })
    }

    private var gigabytes: Binding<Double> {
        Binding(get: { Double(megabytes.wrappedValue) / 1024 },
                set: { megabytes.wrappedValue = Int(($0 * 1024).rounded()) })
    }

    private var isCountAutomatic: Binding<Bool> {
        Binding(get: { rawCount == 0 }, set: { rawCount = $0 ? 0 : manualRawCount })
    }

    private var count: Binding<Int> {
        Binding(get: { rawCount == 0 ? LoupeController.automaticRawCount : rawCount },
                set: { value in
                    let clamped = min(max(value, 1), Self.maxRawCount)
                    manualRawCount = clamped
                    if rawCount != 0 { rawCount = clamped }
                })
    }

    var body: some View {
        Form {
            Section("Frame cache") {
                Picker("Size", selection: isBudgetAutomatic) {
                    Text("Automatic").tag(true)
                    Text("Custom").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Frame cache size mode")
                if budgetMB == 0 {
                    LabeledContent("Size", value: Self.gigabytesText(Self.automaticMB))
                } else {
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: Binding(get: { Double(megabytes.wrappedValue) },
                                                  set: { megabytes.wrappedValue = Int($0 / Double(Self.step)) * Self.step }),
                                   in: Double(Self.step)...Double(Self.maxMB))
                                .frame(minWidth: 140)
                                .accessibilityLabel("Frame cache size")
                                .accessibilityValue("\(megabytes.wrappedValue) megabytes")
                            TextField("GB", value: gigabytes, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                                .accessibilityLabel("Frame cache size in gigabytes")
                            Text("GB").foregroundStyle(.secondary)
                        }
                    }
                }
                note("Memory for decoded frames. Automatic is 2 GB, or a quarter of the RAM when that is less.")
            }
            Section("Cached RAW frames") {
                Picker("Number", selection: isCountAutomatic) {
                    Text("Automatic").tag(true)
                    Text("Custom").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Cached RAW frames mode")
                if rawCount == 0 {
                    LabeledContent("Number", value: "\(LoupeController.automaticRawCount) frames")
                } else {
                    LabeledContent("Number") {
                        HStack {
                            // Exponential: the slider position is the logarithm of the count, so 1 to 20 keep room.
                            Slider(value: Binding(get: { log(Double(count.wrappedValue)) / log(Double(Self.maxRawCount)) },
                                                  set: { count.wrappedValue = Int(pow(Double(Self.maxRawCount), $0).rounded()) }),
                                   in: 0...1)
                                .frame(minWidth: 140)
                                .accessibilityLabel("Cached RAW frames")
                                .accessibilityValue("\(count.wrappedValue) frames")
                            TextField("Frames", value: count, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                                .accessibilityLabel("Cached RAW frames, number")
                            Text("frames").foregroundStyle(.secondary)
                        }
                    }
                }
                note("The frame cache size is the higher limit. If the frames do not fit in it, the oldest ones go first.")
            }
            Section("Thumbnail cache") {
                LabeledContent("On disk") {
                    HStack {
                        Text(thumbnailBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
                            .monospacedDigit()
                            .accessibilityLabel("Thumbnail cache size")
                        Button("Clear Thumbnail Cache") { clearThumbnails() }
                            .disabled(thumbnailBytes == 0)
                    }
                }
                note("Small pictures kept so the grid opens fast, up to 2 GB. Clearing removes only these; they are made again as you browse. Your photos, decisions and recent folders stay.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
        .onAppear {
            if budgetMB > 0 { manualMB = budgetMB }
            if rawCount > 0 { manualRawCount = rawCount }
            refreshThumbnailBytes()
        }
    }

    private func refreshThumbnailBytes() {
        Task.detached {
            let bytes = FrameLoader.sharedThumbnails.totalBytes
            await MainActor.run { thumbnailBytes = bytes }
        }
    }

    private func clearThumbnails() {
        Task.detached {
            FrameLoader.sharedThumbnails.clear()
            let bytes = FrameLoader.sharedThumbnails.totalBytes
            await MainActor.run {
                thumbnailBytes = bytes
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: "Thumbnail cache cleared", .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }

    private static func gigabytesText(_ mb: Int) -> String {
        (Double(mb) / 1024).formatted(.number.precision(.fractionLength(0...2))) + " GB"
    }
}

private func note(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

private struct SidecarsPane: View {
    @AppStorage("sidecarNaming") private var naming = SidecarNaming.stem.rawValue

    var body: some View {
        Form {
            Picker("Sidecar name", selection: $naming) {
                Text("name.xmp  (Lightroom, FastRawViewer)").tag(SidecarNaming.stem.rawValue)
                Text("name.ext.xmp  (darktable style)").tag(SidecarNaming.fullName.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text("Set RawTherapee's “XMP sidecar style” to match: Adobe for name.xmp, darktable for name.ext.xmp.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Sidecars that already exist are not renamed. New ones use this style, and a photo that only has the other style keeps using that file; the inspector shows which one.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

/// Settings → Peaking (V-06): how the focus-peaking overlay looks.
private struct PeakingPane: View {
    @AppStorage(PeakingSettings.modeKey) private var mode = PeakingMode.edges.rawValue
    @AppStorage(PeakingSettings.redKey) private var red = Double(PeakingStyle.defaultColor.x)
    @AppStorage(PeakingSettings.greenKey) private var green = Double(PeakingStyle.defaultColor.y)
    @AppStorage(PeakingSettings.blueKey) private var blue = Double(PeakingStyle.defaultColor.z)
    @AppStorage(PeakingSettings.sensitivityKey) private var sensitivity = PeakingStyle.defaultSensitivity

    private var color: Binding<Color> {
        Binding(get: { Color(.sRGB, red: red, green: green, blue: blue) },
                set: { new in
                    guard let converted = NSColor(new).usingColorSpace(.sRGB) else { return }
                    (red, green, blue) = (Double(converted.redComponent), Double(converted.greenComponent), Double(converted.blueComponent))
                })
    }

    var body: some View {
        Form {
            Section("Focus peaking") {
                Picker("Mode", selection: $mode) {
                    ForEach(PeakingMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Text("Edges marks the outlines of what is sharp. Fine detail marks small detail and texture, and shows more noise. ⇧F in Loupe switches between them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ColorPicker("Color", selection: color, supportsOpacity: false)
                LabeledContent("Sensitivity") {
                    Slider(value: $sensitivity, in: 0...1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Strict")
                    } maximumValueLabel: {
                        Text("Loose")
                    }
                    .accessibilityValue("\(Int((sensitivity * 100).rounded())) percent")
                }
                Text("Strict marks only the strongest edges. Loose marks faint ones too. Magenta is rare in photos, so it stands out.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Reset to Defaults") { PeakingSettings.reset() }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

/// Settings → Clipping: the thresholds behind the H and S overlays.
private struct ClippingPane: View {
    @AppStorage(ClippingSettings.highlightKey) private var highlight = ClippingThresholds.defaultHighlight
    @AppStorage(ClippingSettings.shadowKey) private var shadow = ClippingThresholds.defaultShadow
    @AppStorage(ClippingSettings.patternKey) private var pattern = false

    var body: some View {
        Form {
            Section("Highlight and shadow clipping") {
                Stepper(value: $highlight, in: ClippingThresholds.highlightRange) {
                    LabeledContent("Highlights from", value: "\(highlight)%")
                }
                Stepper(value: $shadow, in: ClippingThresholds.shadowRange) {
                    LabeledContent("Shadows up to", value: "\(shadow)%")
                }
                Toggle("Stripes instead of solid color", isOn: $pattern)
                Text("H marks highlights in red and S marks shadows in blue. A highlight has any channel at or above its threshold; a shadow has all channels at or below. ⌥H in Loupe opens the same values.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Reset to Defaults") { ClippingSettings.reset() }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

/// Settings → Editors (V-12): the apps `⌘E` can open photos in. Missing ones stay listed and cannot be the default.
private struct EditorsPane: View {
    let store: EditorStore

    var body: some View {
        let defaultID = store.defaultEditor?.id
        Form {
            ForEach(store.editors) { editor in
                let installed = store.isInstalled(editor)
                HStack {
                    Button {
                        store.setDefault(editor.id)
                    } label: {
                        Image(systemName: editor.id == defaultID ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(!installed)
                    .accessibilityLabel("\(editor.name) is the default editor")
                    .accessibilityValue(editor.id == defaultID ? "on" : "off")
                    Text(editor.name)
                    Spacer()
                    if !installed { Text("Not installed").foregroundStyle(.secondary) }
                    if !editor.isPreset {
                        Button("Remove") { store.remove(editor.id) }
                            .accessibilityLabel("Remove \(editor.name)")
                    }
                }
                .opacity(installed ? 1 : 0.6)
            }
            Button("Add Editor…") { addEditor() }
            Text("⌘E opens the selected photos in the default editor. ⌥⌘E asks which one. A RAW with its JPEG opens as the RAW. Oxys writes the newest ratings to the sidecars first. Lightroom Classic may only start, or ask to import, instead of opening the files.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url { store.add(appAt: url) }
    }
}
