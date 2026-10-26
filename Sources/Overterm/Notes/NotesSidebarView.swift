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
            if let index = workspace.index {
                NotesTreeList(tree: tree, index: index, theme: theme, showing: showing, actions: actions)
            } else {
                Spacer()
            }
        }
        .background(theme.card)
        // The page starts right under the tabs, inside the title bar's
        // safe area: honoured, it pushed the vault's row below the editor's.
        .ignoresSafeArea()
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
