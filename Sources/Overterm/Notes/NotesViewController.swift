import AppKit
import Combine
import SwiftUI

/// The Notes page (a WorkspaceOverlay over the window's body): the vault's
/// tree on the left, an editor of its own in the middle, the note rendered
/// beside it — Obsidian's source mode and reading view side by side.
///
/// A note only in iCloud is downloaded before the editor gets it (its read
/// would block the main thread a second); a note changed elsewhere — on
/// another Mac, on an iPhone, by an agent — reloads unless you have edits.
@MainActor
final class NotesViewController: NSViewController, NSSplitViewDelegate {
    let workspace: NotesWorkspace
    let editor: EditorViewController
    let chrome: ChromeTheme
    /// What the tree shows selected.
    let showing = NotesShowing()
    /// The sidebar's mode and its search.
    let sidebarState = NotesSidebarState()
    /// The note showing, changed on two devices at once.
    let conflict = NotesConflict()
    private var conflictBar: NSView!
    var actions: NotesSidebarActions?

    private(set) var preview: MarkdownPreviewView!
    private var backlinks: NSView!
    private var split: NSSplitView!
    private var sidebar: NSView!
    private var previewPane: NSView!
    private var welcome: NSView!
    private(set) var downloadLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var cancellables: Set<AnyCancellable> = []
    private var indexObservation: AnyCancellable?
    private var pendingPreview: DispatchWorkItem?
    private var positioned = false
    /// The note asked for while iCloud brings it down.
    private(set) var downloading: String?
    /// Reopening a vault's notes: what the editor reports isn't a change.
    private var restoring = false

    /// The preview beside the editor (⇧⌘V).
    private(set) var showsPreview = true

    init(workspace: NotesWorkspace, chrome: ChromeTheme, background: NSColor, foreground: NSColor, opener: ExternalOpener) {
        self.workspace = workspace
        self.chrome = chrome
        editor = EditorViewController(theme: chrome, background: background, foreground: foreground, opener: opener)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        editor.showsZoom = false
        editor.showsClose = false
        editor.usesGit = false
        editor.writeFile = { [weak self] data, url in
            guard let self else { return try data.write(to: url, options: .atomic) }
            try self.workspace.files.write(data, to: url)
        }
        editor.onTogglePreview = { [weak self] in self?.togglePreview() }
        // The breadcrumb and Go to File from the vault, not the disk's root.
        editor.workspaceRoot = { [weak self] in self?.workspace.root }
        editor.onTextChange = { [weak self] _ in self?.schedulePreview() }
        editor.onShowing = { [weak self] _ in self?.editorShowsAnother() }
        editor.onSaved = { [weak self] in self?.noteSaved() }
        // The last note closed: the page stays, with nothing in it.
        editor.onClose = { [weak self] in self?.editorShowsAnother() }
        addChild(editor)

        editor.completionSource = { [weak self] text, caret in self?.completion(in: text, caret: caret) }
        editor.onPaste = { [weak self] pasteboard in self?.paste(pasteboard) }
        editor.onCommandClick = { [weak self] index in self?.followLink(at: index) ?? false }

        let preview = MarkdownPreviewView(theme: editor.theme)
        // Under the title bar's safe area, as the page is: no inset for it.
        preview.automaticallyAdjustsContentInsets = false
        preview.contentInsets = NSEdgeInsetsZero
        preview.onOpenFile = { [weak self] url in self?.openFile(url) }
        preview.onLink = { [weak self] url in self?.followLink(url) ?? false }
        preview.image = { [weak self] url in self?.embeddedImage(url) }
        self.preview = preview
        let backlinks = NSHostingView(
            rootView: NotesBacklinksView(
                workspace: workspace, showing: showing, theme: chrome,
                open: { [weak self] path, range in self?.open(path, revealing: range) }))
        backlinks.translatesAutoresizingMaskIntoConstraints = false
        self.backlinks = backlinks
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        let previewPane = NSView()
        previewPane.wantsLayer = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        for view in [preview, rule, backlinks] as [NSView] { previewPane.addSubview(view) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: previewPane.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            rule.topAnchor.constraint(equalTo: preview.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            backlinks.topAnchor.constraint(equalTo: rule.bottomAnchor),
            backlinks.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            backlinks.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            backlinks.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
            backlinks.heightAnchor.constraint(equalToConstant: 190),
        ])
        self.previewPane = previewPane

        let sidebar = NSHostingView(rootView: sidebarView)
        self.sidebar = sidebar

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        for view in [sidebar, editor.view, previewPane] as [NSView] { split.addArrangedSubview(view) }
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 2)
        self.split = split

        let welcome = NSHostingView(
            rootView: NotesWelcomeView(
                theme: chrome, canCreateInICloud: AppEnvironment.defaultVaultDirectory != nil,
                create: { [weak self] in self?.actions?.createDefaultVault() },
                choose: { [weak self] in self?.actions?.addVault() }))
        welcome.translatesAutoresizingMaskIntoConstraints = false
        self.welcome = welcome

        let download = NSTextField(labelWithString: "")
        download.font = .systemFont(ofSize: 13)
        download.textColor = editor.theme.text.withAlphaComponent(0.7)
        download.alignment = .center
        download.isHidden = true
        download.translatesAutoresizingMaskIntoConstraints = false
        download.setAccessibilityIdentifier("notes.downloading")
        downloadLabel = download

        let empty = NSTextField(labelWithString: "No note open. ⌘N makes one.")
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = editor.theme.text.withAlphaComponent(0.45)
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel = empty

        let conflictBar = NSHostingView(
            rootView: NotesConflictBar(
                conflict: conflict, theme: chrome, keepMine: { [weak self] in self?.keepMine() },
                useTheirs: { [weak self] in self?.useTheirs($0) }, compare: { [weak self] in self?.compare($0) }))
        conflictBar.translatesAutoresizingMaskIntoConstraints = false
        conflictBar.isHidden = true
        self.conflictBar = conflictBar

        for view in [split, welcome, download, empty, conflictBar] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            welcome.topAnchor.constraint(equalTo: root.topAnchor),
            welcome.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            welcome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            download.centerXAnchor.constraint(equalTo: editor.view.centerXAnchor),
            download.centerYAnchor.constraint(equalTo: editor.view.centerYAnchor),
            download.widthAnchor.constraint(lessThanOrEqualTo: editor.view.widthAnchor, constant: -40),
            empty.centerXAnchor.constraint(equalTo: editor.view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: editor.view.centerYAnchor),
            // Over the foot of the editor, above its status bar.
            conflictBar.leadingAnchor.constraint(equalTo: editor.view.leadingAnchor),
            conflictBar.trailingAnchor.constraint(equalTo: editor.view.trailingAnchor),
            conflictBar.bottomAnchor.constraint(equalTo: editor.view.bottomAnchor, constant: -26),
        ])
        view = root

        workspace.$vault
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.vaultChanged() }
            .store(in: &cancellables)
        workspace.$index
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in self?.observe(index) }
            .store(in: &cancellables)
        sidebarState.$query
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.runSearch() }
            .store(in: &cancellables)
        recolor()
        editorShowsAnother()
    }

    private var sidebarView: NotesSidebarView {
        NotesSidebarView(
            workspace: workspace, vaults: workspace.vaults, tree: workspace.tree, theme: chrome, showing: showing, state: sidebarState,
            actions: NotesSidebarActions(
                open: { [weak self] in self?.openFile($0) },
                newNote: { [weak self] in self?.actions?.newNote($0) },
                newFolder: { [weak self] in self?.actions?.newFolder($0) },
                rename: { [weak self] in self?.actions?.rename($0) },
                trash: { [weak self] in self?.actions?.trash($0) },
                switchVault: { [weak self] in self?.actions?.switchVault($0) },
                addVault: { [weak self] in self?.actions?.addVault() },
                createDefaultVault: { [weak self] in self?.actions?.createDefaultVault() },
                removeVault: { [weak self] in self?.actions?.removeVault($0) },
                openAt: { [weak self] path, range in self?.open(path, revealing: range) }))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The first real width: the tree 240 pt, the rest shared.
        guard !positioned, split.bounds.width > 600 else { return }
        positioned = true
        split.setPosition(240, ofDividerAt: 0)
        split.setPosition(240 + (split.bounds.width - 240) * 0.55, ofDividerAt: 1)
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? 160 : proposedMinimumPosition + 280
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? 420 : proposedMaximumPosition - 200
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === previewPane }

    // MARK: The vault

    private func vaultChanged() {
        let hasVault = workspace.vault != nil
        welcome.isHidden = hasVault
        split.isHidden = !hasVault
        reopenNotes()
    }

    /// The vault's notes as they were left — after a switch of vault, or
    /// the page closed and opened again. Another vault's go (their edits
    /// were asked about first: closeNotes).
    func reopenNotes() {
        downloading = nil
        downloadLabel.isHidden = true
        restoring = true
        while let last = editor.buffers.indices.last { editor.removeBuffer(at: last) }
        let wanted = workspace.openInVault
        for path in wanted.paths {
            // A note gone to iCloud meanwhile isn't brought back for this
            // (the one showing is, below).
            guard let url = workspace.url(for: path), !isOnlyInICloud(url) else { continue }
            editor.open(url)
        }
        if let selected = wanted.selected, let url = workspace.url(for: selected) {
            if let i = editor.buffers.firstIndex(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                editor.activate(i)
            } else if FileManager.default.fileExists(atPath: url.path) {
                restoring = false
                return openFile(url)
            }
        }
        restoring = false
        editorShowsAnother()
    }

    private func observe(_ index: NoteIndex?) {
        indexObservation = index?.$entries
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // After the value lands (@Published fires before).
                DispatchQueue.main.async { self?.vaultFilesChanged() }
            }
    }

    /// FSEvents through the index: a note open here changed or went.
    private func vaultFilesChanged() {
        editor.reloadIfChangedOnDisk()
        if sidebarState.mode == .search { runSearch() }
        updateConflict()
        for buffer in editor.buffers where !buffer.document.isDirty {
            guard let url = buffer.url, !FileManager.default.fileExists(atPath: url.path) else { continue }
            editor.filesRemoved(at: url)
        }
        schedulePreview()
    }

    // MARK: Opening notes

    /// A file of the vault, in the editor — downloaded first if it is only
    /// in iCloud. Not a note (an image, a PDF): the app the Mac opens it with.
    func openFile(_ url: URL, then opened: (() -> Void)? = nil) {
        guard NoteLinks.isNote(url.lastPathComponent) else {
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) || Self.placeholderExists(for: url) else { return }
        if isOnlyInICloud(url) {
            downloading = workspace.path(for: url) ?? url.lastPathComponent
            downloadLabel.stringValue = "Downloading “\(NoteLinks.name(of: url.lastPathComponent))” from iCloud…"
            downloadLabel.isHidden = false
            emptyLabel.isHidden = true
            editor.view.isHidden = true
            workspace.files.startDownloading([url])
            waitForDownload(url, since: Date(), then: opened)
            return
        }
        downloading = nil
        downloadLabel.isHidden = true
        editor.view.isHidden = false
        editor.open(url) { [weak self] ok in
            self?.editor.focus()
            if ok { opened?() }
        }
    }

    /// macOS 13 keeps a note only in iCloud as `.Note.md.icloud` beside
    /// where it would be.
    static func placeholderExists(for url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    private func isOnlyInICloud(_ url: URL) -> Bool {
        workspace.files.state(of: url).download != .local || !FileManager.default.fileExists(atPath: url.path)
    }

    /// Looks again until iCloud has it (or a minute has gone).
    private func waitForDownload(_ url: URL, since start: Date, then opened: (() -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.downloading != nil, self.workspace.path(for: url) == self.downloading else { return }
            if !self.isOnlyInICloud(url) { return self.openFile(url, then: opened) }
            if Date().timeIntervalSince(start) > 60 {
                self.downloadLabel.stringValue = "“\(NoteLinks.name(of: url.lastPathComponent))” didn't come down from iCloud. Is this Mac online?"
                return
            }
            self.waitForDownload(url, since: start, then: opened)
        }
    }

    func open(_ path: String) {
        guard let url = workspace.url(for: path) else { return }
        openFile(url)
    }

    // MARK: What shows

    private func editorShowsAnother() {
        let buffer = editor.active
        showing.url = buffer?.url
        let none = buffer == nil && downloading == nil
        emptyLabel.isHidden = !none || workspace.vault == nil
        if downloading == nil { editor.view.isHidden = false }
        if !restoring {
            let paths = editor.buffers.compactMap { $0.url.flatMap(workspace.path(for:)) }
            workspace.notesShown(paths, selected: buffer?.url.flatMap(workspace.path(for:)))
        }
        conflict.comparing = nil
        updateConflict()
        refreshPreview()
    }

    // MARK: Conflicts

    /// Asks iCloud whether the note showing has versions from another
    /// device; the bar under the editor while it does.
    func updateConflict() {
        let url = editor.active?.url
        let versions = url.map { workspace.files.state(of: $0).hasConflicts ? workspace.files.conflicts(of: $0) : [] } ?? []
        if versions != conflict.versions { conflict.versions = versions }
        if versions.isEmpty, conflict.comparing != nil {
            conflict.comparing = nil
            refreshPreview()
        }
        conflictBar.isHidden = versions.isEmpty
    }

    /// This Mac's text wins (saved first if it has edits); the others go.
    func keepMine() {
        guard let buffer = editor.active, let url = buffer.url else { return }
        if buffer.document.isDirty {
            editor.save(buffer, overwriting: true)
            guard !buffer.document.isDirty else { return }
        }
        resolve(url, keeping: nil)
    }

    /// The other device's text replaces this one — after asking, if this
    /// one has unsaved edits.
    func useTheirs(_ version: ConflictVersion) {
        guard let buffer = editor.active, let url = buffer.url else { return }
        guard buffer.document.isDirty, let window = view.window else { return resolve(url, keeping: version) }
        let alert = NSAlert()
        alert.messageText = "Use \(version.device ?? "the other device")'s version?"
        alert.informativeText = "Your unsaved changes to “\(buffer.name)” will be lost."
        alert.addButton(withTitle: "Use Theirs")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.resolve(url, keeping: version)
        }
    }

    private func resolve(_ url: URL, keeping version: ConflictVersion?) {
        do {
            try workspace.files.resolveConflicts(of: url, keeping: version)
        } catch {
            if let window = view.window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }
        conflict.comparing = nil
        if let buffer = editor.buffers.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { editor.reload(buffer) }
        if let path = workspace.path(for: url), let text = try? workspace.files.readText(url) { workspace.index?.written(path, text: text) }
        updateConflict()
        refreshPreview()
    }

    /// Their version beside yours, in the preview's place (nil: back).
    func compare(_ version: ConflictVersion?) {
        conflict.comparing = version
        if !showsPreview { togglePreview() }
        refreshPreview()
    }

    private func noteSaved() {
        guard let buffer = editor.active, let url = buffer.url, let path = workspace.path(for: url) else { return }
        workspace.index?.noteSaved(path, text: buffer.storage.string)
    }

    private func schedulePreview() {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshPreview() } }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func refreshPreview() {
        guard showsPreview else { return }
        let buffer = editor.active
        preview.baseURL = buffer?.url
        if let theirs = conflict.comparing {
            let text = (try? workspace.files.readText(theirs.url)) ?? ""
            preview.show("> **\(theirs.device ?? "The other device")'s version**\n\n" + NoteRendering.markdown(text))
            return
        }
        let text = buffer?.document.unavailable == nil ? buffer?.storage.string ?? "" : ""
        preview.show(NoteRendering.markdown(text))
    }

    /// The note showing, by its path in the vault.
    var currentPath: String? { editor.active?.url.flatMap(workspace.path(for:)) }

    // MARK: Links

    /// A link clicked in the preview: a note's (opened, or made when it
    /// isn't written yet, as Obsidian does), a tag's (the notes with it).
    func followLink(_ url: URL) -> Bool {
        if let tag = NoteRendering.tag(of: url) {
            showTagged(tag)
            return true
        }
        guard let link = NoteRendering.target(of: url) else { return false }
        follow(link.target, heading: link.heading)
        return true
    }

    func follow(_ target: String, heading: String? = nil) {
        guard let index = workspace.index, let root = workspace.root else { return }
        let source = currentPath ?? ""
        if let path = index.links.resolve(target, style: .wiki, from: source) {
            return open(path, heading: heading)
        }
        guard !target.isEmpty else { return }
        // Not written yet: made — beside the vault's new notes, or where the
        // link's own path says. Already there (the index a pass behind): opened.
        let file = NoteLinks.isNote(target) ? target : target + ".md"
        let folder = target.contains("/") ? root : (workspace.newNotesFolder ?? root)
        let url = folder.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) { return openFile(url) }
        guard let made = try? workspace.newNote(in: url.deletingLastPathComponent(), named: url.lastPathComponent) else { return }
        workspace.tree.reload()
        openFile(made)
    }

    /// A note, at a heading (or a `^block`) if one is named.
    func open(_ path: String, heading: String?) {
        guard let url = workspace.url(for: path) else { return }
        openFile(url) { [weak self] in
            guard let self, let heading, let buffer = self.editor.active else { return }
            let syntax = NoteSyntax.parse(buffer.storage.string)
            let wanted = heading.lowercased()
            if wanted.hasPrefix("^") {
                let marker = " " + wanted
                let text = buffer.storage.string as NSString
                let found = text.range(of: marker, options: .caseInsensitive)
                if found.location != NSNotFound { self.editor.reveal(text.lineRange(for: found), flash: true) }
            } else if let match = syntax.headings.first(where: { $0.text.lowercased() == wanted }) {
                self.editor.reveal(match.range, flash: true)
            }
        }
    }

    /// A note with `range` selected (a backlink's link).
    func open(_ path: String, revealing range: NSRange) {
        guard let url = workspace.url(for: path) else { return }
        openFile(url) { [weak self] in
            guard let self, let buffer = self.editor.active, NSMaxRange(range) <= buffer.storage.length else { return }
            self.editor.reveal(range, flash: true)
        }
    }

    /// `[[` in the editor: the vault's notes (or files, after `![[`).
    private func completion(in text: NSString, caret: Int) -> HostCompletion? {
        guard let index = workspace.index, let source = currentPath, let context = NoteCompletion.context(in: text, caret: caret) else { return nil }
        let suggestions = NoteCompletion.suggestions(
            for: context, files: Array(index.entries.keys), aliases: index.aliases, links: index.links, from: source)
        return HostCompletion(
            anchor: context.anchor, afterCaret: context.isClosed ? 2 : 0,
            items: suggestions.map {
                HostCompletion.Item(
                    title: $0.title, insert: $0.insert, detail: $0.detail, badge: NoteLinks.isNote($0.title) || !$0.title.contains(".") ? "md" : "file",
                    matched: $0.matched)
            })
    }

    /// ⌘-click on a link in the editor: followed, as in the preview.
    func followLink(at index: Int) -> Bool {
        guard let buffer = editor.active else { return false }
        let syntax = NoteSyntax.parse(buffer.storage.string)
        if let tag = syntax.tags.first(where: { NSLocationInRange(index, $0.range) }) {
            showTagged(tag.name)
            return true
        }
        guard let link = syntax.links.first(where: { NSLocationInRange(index, $0.range) }) else { return false }
        if link.isEmbed, NoteRendering.isImage(link.target), let path = workspace.index?.links.resolve(link, from: currentPath ?? ""),
            let url = workspace.url(for: path)
        {
            NSWorkspace.shared.open(url)
            return true
        }
        if link.style == .markdown, let source = currentPath, let path = workspace.index?.links.resolve(link, from: source) {
            open(path, heading: link.heading)
            return true
        }
        follow(link.target, heading: link.heading ?? link.block.map { "^" + $0 })
        return true
    }

    /// `![[shot.png]]` in the preview: the image, if it is on this Mac (one
    /// only in iCloud is asked for, and drawn when it arrives).
    private func embeddedImage(_ url: URL) -> NSImage? {
        guard let target = NoteRendering.embed(of: url), let index = workspace.index,
            let path = index.links.resolve(target, style: .wiki, from: currentPath ?? ""), let file = workspace.url(for: path)
        else { return nil }
        if isOnlyInICloud(file) {
            workspace.files.startDownloading([file])
            return nil
        }
        return NSImage(contentsOf: file)
    }

    /// ⌘V with an image (a screenshot, an image file copied in Finder):
    /// kept in the vault's attachments, embedded where the caret is. Text
    /// on the pasteboard pastes as text.
    private func paste(_ pasteboard: NSPasteboard) -> String? {
        guard workspace.vault != nil else { return nil }
        // Files copied in Finder come with their names as text: files first.
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            guard files.allSatisfy({ NoteRendering.isImage($0.path) }) else { return nil }
            let embeds = files.compactMap { file -> String? in
                guard let data = try? Data(contentsOf: file),
                    let path = try? workspace.saveAttachment(data, ext: file.pathExtension.lowercased(), named: file.deletingPathExtension().lastPathComponent)
                else { return nil }
                return "![[\(NoteLinks.name(of: path))]]"
            }
            workspace.tree.reload()
            return embeds.isEmpty ? nil : embeds.joined(separator: "\n")
        }
        guard pasteboard.string(forType: .string) == nil else { return nil }
        var png = pasteboard.data(forType: .png)
        if png == nil, let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) {
            png = bitmap.representation(using: .png, properties: [:])
        }
        guard let png, let path = try? workspace.saveAttachment(png, ext: "png") else { return nil }
        workspace.tree.reload()
        return "![[\(NoteLinks.name(of: path))]]"
    }

    // MARK: Search

    private func runSearch() {
        guard let index = workspace.index else { return sidebarState.results = [] }
        let notes = index.entries.values.compactMap { entry -> (path: String, text: String, tags: [String])? in
            guard entry.isNote, let text = entry.text else { return nil }
            return (entry.path, text, entry.syntax?.allTags ?? [])
        }
        let results = NoteSearch.search(sidebarState.query, notes: notes)
        if results != sidebarState.results { sidebarState.results = results }
    }

    /// The sidebar on its search, the field ready.
    func showSearch() {
        sidebarState.mode = .search
        runSearch()
    }

    // MARK: Switching

    /// ⌘O: a note by name (or alias); a name no note has makes one.
    func showSwitcher() {
        guard let index = workspace.index else { return }
        var rows: [String?] = []
        let picker = EditorPicker(
            placeholder: "Find a note, or name a new one", theme: editor.theme, showsList: true,
            provider: { [weak self] query in
                guard let self else { return [] }
                let ranked = Self.rank(index: index, query: query, open: self.editor.buffers.compactMap { $0.url.flatMap(self.workspace.path(for:)) })
                rows = ranked.map(\.path)
                var items = ranked.map { EditorListItem(title: $0.title, detail: $0.detail, badge: "md", matched: $0.matched) }
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !ranked.contains(where: { $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
                    rows.append(nil)
                    items.append(EditorListItem(title: "Create “\(trimmed)”", detail: "a new note", badge: "+"))
                }
                return items
            },
            choose: { [weak self] row, text in
                guard let self else { return }
                let name = text.trimmingCharacters(in: .whitespaces)
                if rows.indices.contains(row), let path = rows[row] {
                    self.open(path, heading: nil)
                } else if !name.isEmpty {
                    self.follow(name)
                }
            })
        picker.identifier = NSUserInterfaceItemIdentifier("notesSwitcher")
        editor.view.isHidden = false
        editor.showPicker(picker)
    }

    /// The switcher's rows: open notes first while nothing is typed, then
    /// by how well the name (or an alias) matches.
    static func rank(index: NoteIndex, query: String, open: [String]) -> [(path: String, title: String, detail: String, matched: [Int])] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let notes = index.notes.map(\.path)
        if query.isEmpty {
            let rest = notes.filter { !open.contains($0) }
            return (open.reversed() + rest).prefix(100).map { ($0, NoteLinks.name(of: $0), NoteLinks.folder(of: $0), []) }
        }
        let aliases = index.aliases
        var scored: [(score: Int, row: (path: String, title: String, detail: String, matched: [Int]))] = []
        for path in notes {
            let name = NoteLinks.name(of: path)
            if let match = CompletionMatch.score(candidate: name, query: query) {
                scored.append((match.score + 4, (path, name, NoteLinks.folder(of: path), match.matched)))
            }
            for alias in aliases[path] ?? [] {
                if let match = CompletionMatch.score(candidate: alias, query: query) {
                    scored.append((match.score, (path, alias, "→ \(name)", match.matched)))
                }
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.row.title.count < $1.row.title.count }
        return scored.prefix(100).map(\.row)
    }

    /// A tag clicked: the notes that have it (or a tag under it).
    func showTagged(_ tag: String) {
        guard let index = workspace.index else { return }
        let paths = index.notes(tagged: tag)
        let picker = EditorPicker(
            placeholder: "#\(tag) — \(paths.count) note\(paths.count == 1 ? "" : "s")", theme: editor.theme, showsList: true,
            provider: { query in
                paths.filter { query.isEmpty || NoteLinks.name(of: $0).localizedCaseInsensitiveContains(query) }
                    .map { EditorListItem(title: NoteLinks.name(of: $0), detail: NoteLinks.folder(of: $0), badge: "#") }
            },
            choose: { [weak self] row, query in
                let shown = paths.filter { query.isEmpty || NoteLinks.name(of: $0).localizedCaseInsensitiveContains(query) }
                guard let self, shown.indices.contains(row) else { return }
                self.open(shown[row], heading: nil)
            })
        picker.identifier = NSUserInterfaceItemIdentifier("notesTagged")
        editor.view.isHidden = false
        editor.showPicker(picker)
    }

    /// ⇧⌘V: the preview beside the editor, or the editor alone.
    func togglePreview() {
        showsPreview.toggle()
        previewPane.isHidden = !showsPreview
        split.adjustSubviews()
        if showsPreview { refreshPreview() }
    }

    func focus() {
        if editor.active != nil { editor.focus() } else { view.window?.makeFirstResponder(sidebar) }
    }

    /// The terminal's theme changed: the editor follows (the window tells
    /// it), the preview and the page with it.
    func recolor() {
        preview.theme = editor.theme
        view.layer?.backgroundColor = editor.theme.background.cgColor
        downloadLabel.textColor = editor.theme.text.withAlphaComponent(0.7)
        emptyLabel.textColor = editor.theme.text.withAlphaComponent(0.45)
    }

    var unsavedNames: [String] { editor.unsavedNames }

    /// Every note closed, asking about edits — and still listed as open, to
    /// come back with the vault or the page (reopenNotes). False when one
    /// was kept.
    func closeNotes(then done: @escaping (Bool) -> Void) {
        let kept = workspace.openInVault
        restoring = true
        editor.closeAll { [weak self] closed in
            guard let self else { return done(closed) }
            self.restoring = false
            if closed { self.workspace.notesShown(kept.paths, selected: kept.selected) } else { self.editorShowsAnother() }
            done(closed)
        }
    }
}
