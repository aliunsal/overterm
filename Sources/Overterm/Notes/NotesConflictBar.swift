import SwiftUI

/// What a note changed on two devices at once looks like from here: this
/// Mac's text, and each other device's version iCloud kept.
@MainActor
final class NotesConflict: ObservableObject {
    @Published var versions: [ConflictVersion] = []
    /// The other version shown beside the editor (Compare), or nil.
    @Published var comparing: ConflictVersion?
}

/// Under the editor while the note showing has a conflict: whose change
/// it was, and the three ways out — keep this one, use theirs, compare.
struct NotesConflictBar: View {
    @ObservedObject var conflict: NotesConflict
    @ObservedObject var theme: ChromeTheme
    let keepMine: () -> Void
    let useTheirs: (ConflictVersion) -> Void
    let compare: (ConflictVersion?) -> Void

    var body: some View {
        if let other = conflict.versions.first {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(theme.orangeText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Changed on two devices at once").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Text(verbatim: Self.describe(other, more: conflict.versions.count - 1))
                        .font(.system(size: 11)).foregroundStyle(theme.text2)
                }
                // The words wrap; the buttons never shrink to "U…".
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(conflict.comparing == nil ? "Compare" : "Hide") { compare(conflict.comparing == nil ? other : nil) }
                    .fixedSize()
                    .accessibilityIdentifier("notes.conflict.compare")
                Button("Use Theirs") { useTheirs(other) }
                    .fixedSize()
                    .accessibilityIdentifier("notes.conflict.theirs")
                Button("Keep This One") { keepMine() }
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("notes.conflict.mine")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.menu))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.menuEdge))
            .padding(10)
        }
    }

    static func describe(_ version: ConflictVersion, more: Int) -> String {
        let device = version.device ?? "another device"
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let when = version.modified.map { formatter.localizedString(for: $0, relativeTo: Date()) } ?? ""
        let rest = more > 0 ? " (and \(more) more)" : ""
        return "\(device)'s version\(when.isEmpty ? "" : ", \(when)")\(rest). Keep one; the other goes."
    }
}
