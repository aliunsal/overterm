import AppKit

/// The Notes page (⌥⌘N): made the first time it shows, a page over the
/// body that takes turns with Settings (WorkspaceOverlay).
extension TerminalWindowController {
    func makeNotes() -> NotesViewController? {
        if let notes { return notes }
        guard let theme else { return nil }
        let runtime = GhosttyRuntime.shared
        let controller = NotesViewController(
            workspace: notesWorkspace, chrome: theme, background: runtime.backgroundColor, foreground: runtime.foregroundColor,
            opener: opener)
        controller.actions = NotesSidebarActions(
            open: { [weak self] in self?.notes?.openFile($0) },
            newNote: { [weak self] in self?.newNote(in: $0) },
            newFolder: { [weak self] in self?.newNotesFolder(in: $0) },
            rename: { [weak self] in self?.renameNoteItem($0) },
            trash: { [weak self] in self?.trashNoteItem($0) },
            switchVault: { [weak self] in self?.switchVault(to: $0) },
            addVault: { [weak self] in self?.chooseVaultFolder() },
            createDefaultVault: { [weak self] in self?.createDefaultVault() },
            removeVault: { [weak self] in self?.removeVault($0) })
        _ = controller.view
        notes = controller
        return controller
    }

    /// Shown: the last vault opens, the notes come back, the keyboard goes in.
    func notesShown() {
        notesWorkspace.openLast()
        guard let notes else { return }
        if notes.editor.buffers.isEmpty { notes.reopenNotes() }
        notes.focus()
    }

    // MARK: Menu

    /// ⌥⌘N: the Notes page, or the terminal back.
    @objc func toggleNotes(_ sender: Any?) {
        if store.showingOverlay == .notes { hideOverlay() } else { showOverlay(.notes) }
    }

    /// ⌘N while Notes shows: a new note where new notes go.
    @objc func newNote(_ sender: Any?) {
        guard store.showingOverlay == .notes else { return }
        newNote(in: nil)
    }

    var notesSessionState: NotesState? {
        let isOpen = store.openOverlays.contains(.notes)
        guard isOpen || notesWorkspace.vault != nil else { return nil }
        return notesWorkspace.state(isOpen: isOpen)
    }

    /// From the session: the vault and its notes; the page in the strip if
    /// it was, not covering the tab the session selects.
    func restoreNotes(_ state: NotesState) {
        notesWorkspace.restore(state)
        if state.isOpen { store.openOverlay(.notes) }
    }

    // MARK: Vaults

    func createDefaultVault() {
        do {
            try notesWorkspace.createDefaultVault()
        } catch {
            showNotesError("Couldn't make the vault in iCloud Drive.", error)
        }
    }

    func chooseVaultFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open as Vault"
        panel.message = "A folder of Markdown notes. One in iCloud Drive syncs to your other devices."
        panel.directoryURL = AppEnvironment.iCloudDriveDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.switchVault { do { try self.notesWorkspace.addVault(at: url) } catch { self.showNotesError("Couldn't open the folder.", error) } }
        }
    }

    func switchVault(to vault: Vault) {
        guard vault.id != notesWorkspace.vault?.id else { return }
        switchVault { self.notesWorkspace.activate(vault) }
    }

    /// The notes open now asked about (unsaved edits), then `change`.
    private func switchVault(_ change: @escaping () -> Void) {
        guard let notes, !notes.editor.buffers.isEmpty else { return change() }
        notes.closeNotes { closed in if closed { change() } }
    }

    func removeVault(_ vault: Vault) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(vault.name)” from the list?"
        alert.informativeText = "Its folder and the notes in it stay where they are; you can open it again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.switchVault { self.notesWorkspace.removeVault(vault) }
        }
    }

    // MARK: Notes and folders

    /// A note named "Untitled" (the first free), opened — then named as you
    /// rename it.
    func newNote(in folder: URL?) {
        guard notesWorkspace.vault != nil else { return }
        do {
            let url = try notesWorkspace.newNote(in: folder)
            notesWorkspace.tree.reload()
            notes?.openFile(url)
        } catch {
            showNotesError("Couldn't make the note.", error)
        }
    }

    func newNotesFolder(in folder: URL?) {
        guard let folder = folder ?? notesWorkspace.newNotesFolder else { return }
        askForName(title: "New Folder", detail: "In \(folder.lastPathComponent)", initial: "", action: "Create") { [weak self] name in
            guard let self else { return nil }
            let url = folder.appendingPathComponent(name)
            if let problem = Self.nameProblem(name, at: url) { return problem }
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { return error.localizedDescription }
            self.notesWorkspace.tree.reload()
            return nil
        }
    }

    /// A note keeps its `.md` when renamed without one.
    func renameNoteItem(_ url: URL) {
        let isNote = NoteLinks.isNote(url.lastPathComponent)
        let shown = isNote ? NoteLinks.name(of: url.lastPathComponent) : url.lastPathComponent
        askForName(title: "Rename", detail: url.lastPathComponent, initial: shown, action: "Rename") { [weak self] typed in
            guard let self else { return nil }
            let name = isNote && !NoteLinks.isNote(typed) ? typed + ".md" : typed
            guard name != url.lastPathComponent else { return nil }
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            if name.lowercased() != url.lastPathComponent.lowercased(), let problem = Self.nameProblem(name, at: target) { return problem }
            do { try self.notesWorkspace.files.move(url, to: target) } catch { return error.localizedDescription }
            self.notes?.editor.filesMoved(from: url, to: target)
            self.notesWorkspace.tree.reload()
            self.notesWorkspace.index?.refresh()
            return nil
        }
    }

    func trashNoteItem(_ url: URL) {
        guard let window else { return }
        let path = url.standardizedFileURL.path
        let unsaved =
            notes?.editor.buffers.filter {
                guard let open = $0.url?.standardizedFileURL.path, $0.document.isDirty else { return false }
                return open == path || open.hasPrefix(path + "/")
            }.map(\.name) ?? []
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        var detail = "You can put it back from the Trash."
        if notesWorkspace.vault?.isInICloudDrive == true { detail += " It goes from your other devices too." }
        if !unsaved.isEmpty { detail += " Unsaved changes to \(unsaved.joined(separator: ", ")) will be lost." }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.notesWorkspace.files.trash(url)
            } catch {
                return self.showNotesError("Couldn't move it to the Trash.", error)
            }
            self.notes?.editor.filesRemoved(at: url)
            self.notesWorkspace.tree.reload()
            self.notesWorkspace.index?.refresh()
        }
    }

    private func showNotesError(_ message: String, _ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
