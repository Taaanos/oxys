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
            EditorsPane(store: model.editors).tabItem { Label("Editors", systemImage: "square.and.pencil") }
            AnalysisPane().tabItem { Label("Analysis", systemImage: "scope") }
            SidecarsPane().tabItem { Label("Sidecars", systemImage: "doc.text") }
        }
        .frame(width: 500)
        .scenePadding()
    }
}

private struct GeneralPane: View {
    @AppStorage("prefetchBudgetMB") private var budgetMB = 0
    @AppStorage("rawMode") private var rawMode = RawMode.default.rawValue
    @AppStorage("rawAutoActual") private var rawAutoActual = true
    @AppStorage("pairRawJpeg") private var pairRawJpeg = true
    @AppStorage("autoAdvance") private var autoAdvance = false
    @AppStorage("extractExactBytes") private var extractExactBytes = false
    /// What the slider and field show while Automatic is on, and what returns when it is switched off.
    @State private var manualMB = 2048

    private static let step = 256
    private static let automaticMB = LoupeController.automaticBudget >> 20
    private static let maxMB = max(1024, Int(ProcessInfo.processInfo.physicalMemory >> 20))

    private var isAutomatic: Binding<Bool> {
        Binding(get: { budgetMB == 0 },
                set: { budgetMB = $0 ? 0 : manualMB })
    }

    /// The value shown and edited; every write is clamped to the slider's range.
    private var megabytes: Binding<Int> {
        Binding(get: { budgetMB == 0 ? Self.automaticMB : budgetMB },
                set: { value in
                    let clamped = min(max(value, Self.step), Self.maxMB)
                    manualMB = clamped
                    if budgetMB != 0 { budgetMB = clamped }
                })
    }

    var body: some View {
        Form {
            Toggle("Advance to the next photo after every rating, label or reject", isOn: $autoAdvance)
            Text("Off by default. While it is on, hold ⇧ with a key to apply it and stay on the photo. The A key switches it on and off.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Extract exact bytes, without added EXIF", isOn: $extractExactBytes)
            Text("⇧⌘E copies each RAW's largest embedded JPEG. Many previews have no EXIF block, so they would show sideways and without a date. Off (the default): Oxys adds a small EXIF block with the RAW's orientation, camera and date, and leaves the image data as it is. On: the file is the embedded stream and nothing else. A preview that has its own EXIF is never changed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Show a RAW and its JPEG as one photo", isOn: $pairRawJpeg)
            Text("A RAW and a JPEG or HEIC with the same name in the same folder become one photo. You see the camera JPEG, and a rating goes to the pair. Reveal in Finder selects both files. Switching this changes the open folder at once.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("RAW decode", selection: $rawMode) {
                ForEach(RawMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Automatic RAW at 1:1", isOn: $rawAutoActual)
                .disabled(rawMode == RawMode.never.rawValue)
            Text("Never shows embedded previews only. On demand develops with R, and at 1:1 when the preview has fewer pixels than the sensor. Always develops every RAW, and its neighbors in the background. ⇧R switches to Always until you quit.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Choose the frame cache size automatically", isOn: isAutomatic)
            LabeledContent("Frame cache") {
                HStack {
                    Slider(value: Binding(get: { Double(megabytes.wrappedValue) },
                                          set: { megabytes.wrappedValue = Int($0 / Double(Self.step)) * Self.step }),
                           in: Double(Self.step)...Double(Self.maxMB))
                        .frame(minWidth: 140)
                        .accessibilityLabel("Frame cache size")
                        .accessibilityValue("\(megabytes.wrappedValue) megabytes")
                    TextField("MB", value: megabytes, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .accessibilityLabel("Frame cache size in megabytes")
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            .disabled(budgetMB == 0)
            Text("Memory used to keep decoded frames ready for the next photos. Automatic is 2 GB, or a quarter of the RAM when that is less.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .onAppear { if budgetMB > 0 { manualMB = budgetMB } }
    }
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
    }
}

/// How the analysis overlays look (V-06 focus peaking, V-07 clipping).
private struct AnalysisPane: View {
    @AppStorage(PeakingSettings.modeKey) private var mode = PeakingMode.edges.rawValue
    @AppStorage(PeakingSettings.redKey) private var red = Double(PeakingStyle.defaultColor.x)
    @AppStorage(PeakingSettings.greenKey) private var green = Double(PeakingStyle.defaultColor.y)
    @AppStorage(PeakingSettings.blueKey) private var blue = Double(PeakingStyle.defaultColor.z)
    @AppStorage(PeakingSettings.sensitivityKey) private var sensitivity = PeakingStyle.defaultSensitivity
    @AppStorage(ClippingSettings.highlightKey) private var highlight = ClippingThresholds.defaultHighlight
    @AppStorage(ClippingSettings.shadowKey) private var shadow = ClippingThresholds.defaultShadow
    @AppStorage(ClippingSettings.patternKey) private var pattern = false

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
