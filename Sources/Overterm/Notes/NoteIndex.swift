import Foundation

/// A file in a vault as the index last saw it.
struct NoteEntry: Equatable, Sendable {
    /// Relative to the vault: `Projects/Overterm.md`.
    var path: String
    var size: Int
    var modified: Date
    var cloud: CloudState
    /// Read and parsed — a note's, once it is on this Mac. Nil for any
    /// other file, a note still in iCloud, or one that isn't UTF-8 text.
    var syntax: NoteSyntax?
    var text: String?
    /// These contents were read (or tried: too big, not UTF-8).
    var isRead = false

    var isNote: Bool { NoteLinks.isNote(path) }
    /// Same size and date: the same text. Evicting a file to iCloud and
    /// bringing it back changes neither (the spike), only its cloud state.
    func sameContents(as other: NoteEntry) -> Bool { size == other.size && modified == other.modified }
}

/// Everything about a vault's notes that needs every note read: names,
/// links and backlinks, tags, the text to search. Built in the background
/// and kept current as files change — here, on another Mac, on an iPhone.
///
/// - A note is read again only when its size or date changed: FSEvents
///   reports a file going to iCloud and coming back as a change too.
/// - Notes only in iCloud are all asked for at once and read as they
///   arrive, so backlinks are whole (notes are small; a missing backlink
///   is silently wrong). Other files are listed, never downloaded.
/// - Reads block — a second a note while iCloud fetches it — so they run
///   on a queue of their own, never the main thread nor Swift
///   concurrency's pool.
@MainActor
final class NoteIndex: ObservableObject {
    let root: URL
    let files: CloudFiles
    /// Every file, by path.
    @Published private(set) var entries: [String: NoteEntry] = [:]
    /// The first pass is done (notes in iCloud may still be on the way).
    @Published private(set) var isReady = false

    private let worker: Worker
    private var watcher: DirectoryWatcher?
    private var refreshing = false
    private var again = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cache: Derived?

    /// How long to wait before looking again at notes iCloud is bringing
    /// down; FSEvents usually says first.
    static let downloadPoll: TimeInterval = 1

    init(root: URL, files: CloudFiles) {
        self.root = root.standardizedFileURL
        self.files = files
        worker = Worker(root: self.root, files: files)
    }

    /// The first pass, and changes from then on.
    func start() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(root: root) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Looks again (one pass at a time; asked during one, one more after).
    func refresh() {
        guard !refreshing else {
            again = true
            return
        }
        refreshing = true
        let worker = worker
        DispatchQueue.global(qos: .utility).async {
            let result = worker.pass()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finished(result) }
            }
        }
    }

    /// Resolves once a pass that began after this call has finished.
    func refreshed() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if refreshing { again = true } else { refresh() }
        }
    }

    private func finished(_ result: Worker.Pass) {
        refreshing = false
        if let entries = result.entries {
            self.entries = entries
            cache = nil
        }
        if !isReady { isReady = true }
        if again {
            again = false
            refresh()
            return
        }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
        if result.downloading {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.downloadPoll) { [weak self] in self?.refresh() }
        }
    }

    // MARK: What the notes say

    private struct Derived {
        let links: NoteLinks
        /// Target path → the notes linking to it, and with which links.
        let backlinks: [String: [(source: String, link: NoteSyntax.Link)]]
        /// Tag, lowercased → its name as first written, and the notes.
        let tags: [String: (name: String, notes: [String])]
    }

    private var derived: Derived {
        if let cache { return cache }
        let paths = entries.keys.sorted()
        let links = NoteLinks(files: paths)
        var backlinks: [String: [(source: String, link: NoteSyntax.Link)]] = [:]
        var tags: [String: (name: String, notes: [String])] = [:]
        for path in paths {
            guard let syntax = entries[path]?.syntax else { continue }
            for link in syntax.links {
                guard let target = links.resolve(link, from: path), target != path else { continue }
                backlinks[target, default: []].append((path, link))
            }
            for tag in syntax.allTags {
                let key = tag.lowercased()
                var entry = tags[key] ?? (tag, [])
                entry.notes.append(path)
                tags[key] = entry
            }
        }
        let derived = Derived(links: links, backlinks: backlinks, tags: tags)
        cache = derived
        return derived
    }

    var links: NoteLinks { derived.links }

    /// The notes, by path.
    var notes: [NoteEntry] { entries.values.filter(\.isNote).sorted { $0.path < $1.path } }

    /// Who links to `path`: each note once, with its links there.
    func backlinks(to path: String) -> [(source: String, links: [NoteSyntax.Link])] {
        var order: [String] = []
        var bySource: [String: [NoteSyntax.Link]] = [:]
        for (source, link) in derived.backlinks[path] ?? [] {
            if bySource[source] == nil { order.append(source) }
            bySource[source, default: []].append(link)
        }
        return order.map { ($0, bySource[$0] ?? []) }
    }

    /// Every tag and how many notes have it, by name.
    var tags: [(name: String, count: Int)] {
        derived.tags.values.map { ($0.name, $0.notes.count) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The notes tagged `tag` — or with a tag under it (`project` finds
    /// `project/overterm`).
    func notes(tagged tag: String) -> [String] {
        let key = tag.lowercased()
        let paths = derived.tags.filter { $0.key == key || $0.key.hasPrefix(key + "/") }.flatMap(\.value.notes)
        return Array(Set(paths)).sorted()
    }

    /// The file a link in `source` points at.
    func resolve(_ link: NoteSyntax.Link, from source: String) -> String? { derived.links.resolve(link, from: source) }

    /// What renaming `old` to `new` rewrites in the notes (NoteLinks).
    func renameEdits(old: String, new: String) -> [String: [NoteLinks.Edit]] {
        renameEdits(moves: [old: new])
    }

    /// The same for several at once (a folder's notes); `overriding` gives
    /// a note's links as an editor has it, unsaved, instead of as read.
    func renameEdits(moves: [String: String], overriding: [String: [NoteSyntax.Link]] = [:]) -> [String: [NoteLinks.Edit]] {
        var links = entries.compactMapValues { $0.syntax?.links }
        links.merge(overriding) { _, edited in edited }
        return NoteLinks.renameEdits(moves: moves, files: Array(entries.keys), links: links)
    }

    /// Each note's aliases (frontmatter), for completion and the switcher.
    var aliases: [String: [String]] {
        entries.compactMapValues { $0.syntax?.frontmatter?.aliases }.filter { !$0.value.isEmpty }
    }

    /// The line a link is on, trimmed: a backlink's context.
    func context(of link: NoteSyntax.Link, in source: String) -> String {
        guard let text = entries[source]?.text else { return "" }
        let ns = text as NSString
        guard NSMaxRange(link.range) <= ns.length else { return "" }
        return ns.substring(with: ns.lineRange(for: link.range)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A file just written from here — a note saved or made, an image
    /// pasted: in the index now, without waiting for FSEvents and a pass
    /// (a second or two behind). A link to a note just made resolves at once.
    func written(_ path: String, text: String? = nil) {
        var entry =
            entries[path]
            ?? NoteEntry(path: path, size: 0, modified: Date(), cloud: .local, syntax: nil, text: nil)
        if let values = try? url(for: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            entry.size = values.fileSize ?? entry.size
            entry.modified = values.contentModificationDate ?? entry.modified
        }
        if let text, entry.isNote {
            entry.text = text
            entry.syntax = NoteSyntax.parse(text)
            entry.isRead = true
        }
        entries[path] = entry
        cache = nil
        refresh()
    }

    func noteSaved(_ path: String, text: String) { written(path, text: text) }

    func url(for path: String) -> URL { root.appendingPathComponent(path) }

    func path(for url: URL) -> String? {
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(root.path + "/") else { return nil }
        return String(full.dropFirst(root.path.count + 1))
    }
}

extension NoteIndex {
    /// The background half: lists the vault, reads what changed. Its state
    /// is touched only by one pass at a time (NoteIndex runs one), on
    /// whichever thread that pass is on.
    final class Worker: @unchecked Sendable {
        struct Pass {
            /// The new entries, or nil when nothing changed.
            var entries: [String: NoteEntry]?
            /// Notes are still coming down from iCloud: look again soon.
            var downloading: Bool
        }

        let root: URL
        let files: CloudFiles
        private var known: [String: NoteEntry] = [:]
        private var requested = Set<String>()
        /// A note is read only up to this; the editor's limit.
        static let largest = 5 << 20

        init(root: URL, files: CloudFiles) {
            self.root = root
            self.files = files
        }

        func pass() -> Pass {
            let listed = Self.list(root, files: files)
            var next: [String: NoteEntry] = [:]
            var toDownload: [URL] = []
            var downloading = false
            for (path, var entry) in listed {
                if let old = known[path], old.sameContents(as: entry), old.isRead || !entry.isNote || entry.cloud.download != .local {
                    // Unchanged: keep what was read, take the new cloud state.
                    entry.syntax = old.syntax
                    entry.text = old.text
                    entry.isRead = old.isRead
                    if entry.isNote, !old.isRead { downloading = true }
                    next[path] = entry
                    continue
                }
                if entry.isNote {
                    if entry.cloud.download == .local {
                        Self.read(&entry, at: root.appendingPathComponent(path), files: files)
                        requested.remove(path)
                    } else {
                        downloading = true
                        if requested.insert(path).inserted { toDownload.append(root.appendingPathComponent(path)) }
                        // What was read before stays until the new text arrives.
                        if let old = known[path] {
                            entry.syntax = old.syntax
                            entry.text = old.text
                        }
                    }
                }
                next[path] = entry
            }
            if !toDownload.isEmpty { files.startDownloading(toDownload) }
            requested = requested.filter { next[$0] != nil }
            defer { known = next }
            return Pass(entries: next == known ? nil : next, downloading: downloading)
        }

        static func read(_ entry: inout NoteEntry, at url: URL, files: CloudFiles) {
            entry.isRead = true
            guard entry.size <= largest, let text = try? files.readText(url) else {
                entry.syntax = nil
                entry.text = nil
                return
            }
            entry.text = text
            entry.syntax = NoteSyntax.parse(text)
        }

        /// Every file under `root`, by its path there; hidden ones and an
        /// atomic write's leftovers aside, macOS 13's placeholders as the
        /// files they stand for. Nothing is downloaded.
        static func list(_ root: URL, files: CloudFiles) -> [String: NoteEntry] {
            var result: [String: NoteEntry] = [:]
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            else { return result }
            let base = root.path.count + 1
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if name.hasPrefix(".") { enumerator.skipDescendants() }
                    continue
                }
                var fileURL = url
                var cloud: CloudState?
                if let real = CloudPlaceholder.file(forPlaceholder: name) {
                    fileURL = url.deletingLastPathComponent().appendingPathComponent(real)
                    cloud = CloudState(download: .cloud)
                } else if CloudPlaceholder.isHidden(name) {
                    continue
                }
                let full = fileURL.standardizedFileURL.path
                guard full.count > base else { continue }
                let path = String(full.dropFirst(base))
                result[path] = NoteEntry(
                    path: path, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast,
                    cloud: cloud ?? files.state(of: fileURL), syntax: nil, text: nil)
            }
            return result
        }
    }
}
