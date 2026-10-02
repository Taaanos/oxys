import Imaging
import Sidecar
import SwiftUI

/// The Settings window (`⌘,`, M-22). Panes arrive with their features; the MVP has General and Sidecars.
/// Values live in user defaults and apply at once; the keymap keeps its own file (M-05).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
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
