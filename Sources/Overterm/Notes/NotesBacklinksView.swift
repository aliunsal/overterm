import SwiftUI

/// Under the preview: the notes that link to the one showing, each with
/// the line its link is on. A click opens it there.
struct NotesBacklinksView: View {
    @ObservedObject var workspace: NotesWorkspace
    @ObservedObject var showing: NotesShowing
    @ObservedObject var theme: ChromeTheme
    let open: (String, NSRange) -> Void

    var body: some View {
        if let index = workspace.index, let url = showing.url, let path = workspace.path(for: url) {
            BacklinkList(index: index, path: path, theme: theme, open: open)
        } else {
            Color.clear
        }
    }
}

private struct BacklinkList: View {
    @ObservedObject var index: NoteIndex
    let path: String
    @ObservedObject var theme: ChromeTheme
    let open: (String, NSRange) -> Void

    var body: some View {
        let backlinks = index.backlinks(to: path)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: backlinks.isEmpty ? "No backlinks" : "Linked from \(backlinks.count) note\(backlinks.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.text2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(backlinks, id: \.source) { backlink in
                        BacklinkRow(
                            name: NoteLinks.name(of: backlink.source), folder: NoteLinks.folder(of: backlink.source),
                            context: backlink.links.first.map { index.context(of: $0, in: backlink.source) } ?? "", theme: theme
                        ) {
                            open(backlink.source, backlink.links.first?.range ?? NSRange(location: 0, length: 0))
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .accessibilityIdentifier("notes.backlinks")
    }
}

private struct BacklinkRow: View {
    let name: String
    let folder: String
    let context: String
    @ObservedObject var theme: ChromeTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: name).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
                if !folder.isEmpty { Text(verbatim: folder).font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1) }
            }
            if !context.isEmpty {
                Text(verbatim: context).font(.system(size: 11)).foregroundStyle(theme.text2).lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
