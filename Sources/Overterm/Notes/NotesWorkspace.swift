import Foundation

/// The notes open in a vault, in tab order, and the one showing.
struct OpenNotes: Codable, Equatable {
    var paths: [String] = []
    var selected: String?
}

/// What the session keeps of the Notes page (SessionState.notes).
struct NotesState: Codable, Equatable {
    var isOpen: Bool
    var vault: UUID?
    /// By vault id.
    var open: [String: OpenNotes] = [:]
}

/// A window's notes: the vault open in its Notes page, its index and its
/// tree, and per vault the notes that were open — so switching vaults and
/// coming back finds them as you left them.
@MainActor
final class NotesWorkspace: ObservableObject {
    let vaults: NoteVaults
    /// iCloud Drive, or what plays it in a test (SimulatedCloudFiles). Set
    /// before a vault opens.
    var files: CloudFiles
    @Published private(set) var vault: Vault?
    @Published private(set) var index: NoteIndex?
    /// The vault's own layout (`.overterm/notes.json`), read in the
    /// background: it may be in iCloud.
    @Published private(set) var config = VaultConfig()
    @Published private(set) var open: [UUID: OpenNotes] = [:]
    let tree = FileTreeModel()

    init(vaults: NoteVaults, files: CloudFiles = ICloudDriveFiles()) {
        self.vaults = vaults
        self.files = files
        tree.isVault = true
    }

    /// The vault last open, if none is yet.
    func openLast() {
        if vault == nil, let last = vaults.current { activate(last) }
    }

    func activate(_ vault: Vault) {
        guard vault.id != self.vault?.id else { return }
        index?.stop()
        self.vault = vault
        let index = NoteIndex(root: vault.url, files: files)
        self.index = index
        index.start()
        tree.setRoot(vault.url)
        vaults.opened(vault)
        config = VaultConfig()
        let files = files
        let root = vault.url
        let id = vault.id
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = VaultConfig.load(from: root, files: files)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if self?.vault?.id == id { self?.config = loaded }
                }
            }
        }
    }

    /// "iCloud Drive › Overterm Notes" (an isolated run's own folder), made
    /// and opened. Only when the user asks: it reaches all their devices.
    @discardableResult
    func createDefaultVault() throws -> Vault {
        guard let folder = AppEnvironment.defaultVaultDirectory else { throw CocoaError(.fileNoSuchFile) }
        let vault = try vaults.add(folder, name: "Overterm Notes")
        activate(vault)
        return vault
    }

    @discardableResult
    func addVault(at folder: URL) throws -> Vault {
        let vault = try vaults.add(folder)
        activate(vault)
        return vault
    }

    /// Out of the list (its notes stay); the next one opens, if any.
    func removeVault(_ vault: Vault) {
        vaults.remove(vault)
        open[vault.id] = nil
        guard self.vault?.id == vault.id else { return }
        index?.stop()
        index = nil
        self.vault = nil
        tree.setRoot(nil)
        if let next = vaults.current { activate(next) }
    }

    // MARK: Notes

    var root: URL? { vault?.url }

    func url(for path: String) -> URL? { root?.appendingPathComponent(path) }

    func path(for url: URL) -> String? {
        guard let root else { return nil }
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    /// Where a new note goes unless a folder is given: the vault's
    /// `newNotesFolder`.
    var newNotesFolder: URL? {
        let folder = VaultConfig.folder(config.newNotesFolder)
        return folder.isEmpty ? root : root?.appendingPathComponent(folder, isDirectory: true)
    }

    /// "Untitled.md", or the first "Untitled N.md" free, in `folder`.
    static func freeName(_ base: String, ext: String = "md", in folder: URL) -> String {
        func name(_ n: Int) -> String {
            let stem = n == 0 ? base : "\(base) \(n)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var n = 0
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name(n)).path) { n += 1 }
        return name(n)
    }

    /// An empty note, written now (through iCloud), named the first free
    /// "Untitled".
    func newNote(in folder: URL? = nil, named name: String? = nil) throws -> URL {
        guard let folder = folder ?? newNotesFolder else { throw CocoaError(.fileNoSuchFile) }
        let file = name.map { $0.lowercased().hasSuffix(".md") ? $0 : $0 + ".md" } ?? Self.freeName("Untitled", in: folder)
        let url = folder.appendingPathComponent(file)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try files.writeText("", to: url)
        index?.refresh()
        return url
    }

    /// What is open in the vault showing, as the page has it now.
    func notesShown(_ paths: [String], selected: String?) {
        guard let id = vault?.id else { return }
        let now = OpenNotes(paths: paths, selected: selected)
        if open[id] != now { open[id] = now }
    }

    var openInVault: OpenNotes { vault.flatMap { open[$0.id] } ?? OpenNotes() }

    // MARK: Session

    func state(isOpen: Bool) -> NotesState {
        NotesState(
            isOpen: isOpen, vault: vault?.id,
            open: Dictionary(uniqueKeysWithValues: open.filter { !$0.value.paths.isEmpty }.map { ($0.key.uuidString, $0.value) }))
    }

    func restore(_ state: NotesState) {
        open = Dictionary(uniqueKeysWithValues: state.open.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        if let id = state.vault, let vault = vaults.vaults.first(where: { $0.id == id }) { activate(vault) }
    }
}
