import AppKit
import SwiftUI

/// What the Notes page's sidebar asks the window to do.
struct NotesSidebarActions {
    var open: (URL) -> Void
    /// A new note or folder in this folder (nil: where new notes go).
    var newNote: (URL?) -> Void
    var newFolder: (URL?) -> Void
    var rename: (URL) -> Void
    var trash: (URL) -> Void
    var switchVault: (Vault) -> Void
    var addVault: () -> Void
    var createDefaultVault: () -> Void
    var removeVault: (Vault) -> Void
    /// A note at a place in it (a search hit).
    var openAt: (String, NSRange) -> Void = { _, _ in }
}

/// What the sidebar shows — the tree, a search, the tags — and the search.
@MainActor
final class NotesSidebarState: ObservableObject {
    enum Mode: String { case files, search, tags }
    @Published var mode: Mode = .files
    @Published var query = ""
    @Published var results: [NoteSearch.Result] = []
}

/// The vault switcher at the top, the vault's tree under it: notes by
/// their names (no `.md`), what is only in iCloud marked with a cloud.
struct NotesSidebarView: View {
    @ObservedObject var workspace: NotesWorkspace
    @ObservedObject var vaults: NoteVaults
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var theme: ChromeTheme
    /// The note in the editor, to show it selected.
    @ObservedObject var showing: NotesShowing
    @ObservedObject var state: NotesSidebarState
    let actions: NotesSidebarActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                vaultMenu
                Spacer(minLength: 0)
                PanelHeaderButton(symbol: "square.and.pencil", help: "New Note (⌘N)", action: { actions.newNote(nil) }, theme: theme)
                PanelHeaderButton(symbol: "folder.badge.plus", help: "New Folder", action: { actions.newFolder(nil) }, theme: theme)
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 34)
            modes
            if let index = workspace.index {
                switch state.mode {
                case .files: NotesTreeList(tree: tree, index: index, theme: theme, showing: showing, actions: actions)
                case .search: NotesSearchList(state: state, theme: theme, actions: actions)
                case .tags: NotesTagList(index: index, state: state, theme: theme)
                }
            } else {
                Spacer()
            }
        }
        .background(theme.card)
        // The page starts right under the tabs, inside the title bar's
        // safe area: honoured, it pushed the vault's row below the editor's.
        .ignoresSafeArea()
    }

    private var modes: some View {
        HStack(spacing: 2) {
            mode(.files, "folder", "Files")
            mode(.search, "magnifyingglass", "Search")
            mode(.tags, "number", "Tags")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func mode(_ mode: NotesSidebarState.Mode, _ symbol: String, _ title: String) -> some View {
        Button {
            state.mode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 22)
                .foregroundStyle(state.mode == mode ? theme.text : theme.text3)
                .background(RoundedRectangle(cornerRadius: 5).fill(state.mode == mode ? theme.rowSel : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityIdentifier("notes.mode.\(mode.rawValue)")
    }

    private var vaultMenu: some View {
        Menu {
            ForEach(vaults.vaults) { vault in
                Button {
                    actions.switchVault(vault)
                } label: {
                    if vault.id == workspace.vault?.id { Label(vault.name, systemImage: "checkmark") } else { Text(vault.name) }
                }
            }
            Divider()
            Button("Open Folder as Vault…") { actions.addVault() }
            if let folder = AppEnvironment.defaultVaultDirectory, !vaults.vaults.contains(where: { $0.path == folder.standardizedFileURL.path }) {
                Button("Create “Overterm Notes” in iCloud Drive") { actions.createDefaultVault() }
            }
            if let vault = workspace.vault {
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vault.url]) }
                Button("Remove “\(vault.name)” from the List") { actions.removeVault(vault) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: workspace.vault?.isInICloudDrive == true ? "icloud" : "folder")
                    .font(.system(size: 11))
                Text(verbatim: workspace.vault?.name ?? "No Vault")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(theme.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(workspace.vault?.path ?? "Vaults")
        .accessibilityIdentifier("notes.vaultMenu")
    }
}

/// Which note the editor shows, for the tree's selection.
@MainActor
final class NotesShowing: ObservableObject {
    @Published var url: URL?
}

private struct NotesTreeList: View {
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var index: NoteIndex
    @ObservedObject var theme: ChromeTheme
    @ObservedObject var showing: NotesShowing
    let actions: NotesSidebarActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tree.rows) { row in
                    NotesRowView(
                        row: row, tree: tree, cloud: index.path(for: row.entry.url).flatMap { index.entries[$0]?.cloud },
                        selected: showing.url?.standardizedFileURL == row.entry.url.standardizedFileURL, theme: theme,
                        actions: actions)
                }
            }
            .padding(.vertical, 4)
        }
        .contextMenu {
            Button("New Note") { actions.newNote(nil) }
            Button("New Folder") { actions.newFolder(nil) }
        }
    }
}

private struct NotesRowView: View {
    let row: FileRow
    @ObservedObject var tree: FileTreeModel
    let cloud: CloudState?
    let selected: Bool
    @ObservedObject var theme: ChromeTheme
    let actions: NotesSidebarActions
    @State private var hovering = false

    private var isNote: Bool { !row.entry.isDirectory && NoteLinks.isNote(row.entry.name) }

    private var symbol: String {
        if row.entry.isDirectory { return "folder" }
        if isNote { return "doc.text" }
        let ext = row.entry.url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff"].contains(ext) ? "photo" : "doc"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10)
                .opacity(row.entry.isDirectory ? 1 : 0)
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(verbatim: isNote ? NoteLinks.name(of: row.entry.name) : row.entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let cloud, cloud.download != .local || cloud.hasConflicts {
                Image(systemName: cloud.hasConflicts ? "exclamationmark.icloud" : (cloud.download == .downloading ? "icloud.and.arrow.down" : "icloud"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text3)
                    .help(cloud.hasConflicts ? "Changed on two devices at once" : (cloud.download == .downloading ? "Downloading from iCloud" : "In iCloud"))
            }
        }
        .foregroundStyle(selected ? theme.text : theme.text2)
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? theme.rowSel : (hovering ? theme.rowHover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if row.entry.isDirectory { tree.toggle(row) } else { actions.open(row.entry.url) }
        }
        .onDrag { FileTreeDrag.item(for: row.entry.url) }
        .contextMenu { menu }
        .help(row.entry.url.path)
    }

    @ViewBuilder private var menu: some View {
        let url = row.entry.url
        let folder = row.entry.isDirectory ? url : url.deletingLastPathComponent()
        Button("New Note") { actions.newNote(folder) }
        Button("New Folder") { actions.newFolder(folder) }
        Divider()
        if !row.entry.isDirectory { Button("Open") { actions.open(url) } }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        Divider()
        Button("Rename…") { actions.rename(url) }
        Button("Move to Trash…") { actions.trash(url) }
    }
}

/// The search: a field, then each note that matches with the lines it
/// matches on.
private struct NotesSearchList: View {
    @ObservedObject var state: NotesSidebarState
    @ObservedObject var theme: ChromeTheme
    let actions: NotesSidebarActions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search notes — words, \"a phrase\", #tag", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .focused($focused)
                .onAppear { focused = true }
                .accessibilityIdentifier("notes.searchField")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(state.results, id: \.path) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: NoteLinks.name(of: result.path))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { actions.openAt(result.path, result.hits.first?.range ?? NSRange(location: 0, length: 0)) }
                            ForEach(result.hits, id: \.range.location) { hit in
                                Text(verbatim: hit.context)
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.text2)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { actions.openAt(result.path, hit.range) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                    }
                    if !state.query.isEmpty, state.results.isEmpty {
                        Text("Nothing found").font(.system(size: 11)).foregroundStyle(theme.text3).padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

/// Every tag in the vault and how many notes have it; a click searches it.
private struct NotesTagList: View {
    @ObservedObject var index: NoteIndex
    @ObservedObject var state: NotesSidebarState
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(index.tags, id: \.name) { tag in
                    HStack {
                        Text(verbatim: "#" + tag.name).font(.system(size: 12)).foregroundStyle(theme.text2)
                        Spacer()
                        Text(verbatim: "\(tag.count)").font(.system(size: 11)).foregroundStyle(theme.text3)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.query = "#" + tag.name
                        state.mode = .search
                    }
                }
                if index.tags.isEmpty {
                    Text("No tags yet — #tag in a note, or tags: in its frontmatter.")
                        .font(.system(size: 11)).foregroundStyle(theme.text3).padding(12)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The page with no vault yet: where notes could live, and the two ways to
/// get there. Nothing is made in iCloud Drive until asked — it reaches
/// every one of the user's devices.
struct NotesWelcomeView: View {
    @ObservedObject var theme: ChromeTheme
    let canCreateInICloud: Bool
    let create: () -> Void
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.text2)
            Text("Notes")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(
                "Markdown notes in a folder, linked with [[wikilinks]] and #tags. In iCloud Drive they reach your other Macs, and your iPhone in the Files app."
            )
            .font(.system(size: 13))
            .foregroundStyle(theme.text2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Create “Overterm Notes” in iCloud Drive", action: create)
                    .disabled(!canCreateInICloud)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("notes.createVault")
                Button("Choose a Folder…", action: choose)
                    .accessibilityIdentifier("notes.chooseVault")
            }
            if !canCreateInICloud {
                Text("iCloud Drive is off on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card)
        .ignoresSafeArea()
    }
}
