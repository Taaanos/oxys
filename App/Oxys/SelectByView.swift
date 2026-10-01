import Library
import SwiftUI

/// The ⌥⌘A popover: pick a rating rule and a label rule, `Return` selects, `Esc` closes. Both pickers are
/// segmented, so arrow keys change the choice and `⇥` moves between them.
struct SelectByView: View {
    let done: (SelectionCriteria?) -> Void

    @State private var rating = 0
    @State private var label = 0

    private static let ratings: [(String, SelectionCriteria.Rating?)] = [
        ("Any", nil), ("★1+", .atLeast(1)), ("★2+", .atLeast(2)), ("★3+", .atLeast(3)), ("★4+", .atLeast(4)),
        ("★5", .atLeast(5)), ("None", .unrated), ("Rejected", .rejected),
    ]
    private static let labels: [(String, SelectionCriteria.Label?)] = [
        ("Any", nil), ("None", .unlabeled), ("Red", .color(.red)), ("Yellow", .color(.yellow)),
        ("Green", .color(.green)), ("Blue", .color(.blue)), ("Purple", .color(.purple)),
    ]

    private var criteria: SelectionCriteria {
        SelectionCriteria(rating: Self.ratings[rating].1, label: Self.labels[label].1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select by").font(.headline)
            Picker("Rating", selection: $rating) {
                ForEach(Self.ratings.indices, id: \.self) { Text(Self.ratings[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Label", selection: $label) {
                ForEach(Self.labels.indices, id: \.self) { Text(Self.labels[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text(criteria.isEmpty ? "Every photo" : criteria.summary.capitalizedFirst)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Select") { done(criteria) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
