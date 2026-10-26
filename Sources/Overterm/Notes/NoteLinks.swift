import Foundation

/// Which file a link means, and what a rename has to rewrite — Obsidian's
/// rules, over a vault's files.
///
/// Paths are relative to the vault, `/`-separated: `Projects/Overterm.md`,
/// `attachments/shot.png`. A note's name is its file name without `.md`;
/// any other file's name keeps its extension. Matching ignores case and
/// Unicode normalization (APFS does; a name typed on an iPhone may be
/// composed differently from the one on disk).
///
/// A `[[link]]` resolves to, in order:
/// 1. the path it gives, from the linking note's folder (`.md` may be
///    left off);
/// 2. that path from the vault's root;
/// 3. a file whose path ends with it (`[[Projects/Overterm]]`);
/// 4. a file of that name anywhere.
///
/// Several candidates: the one nearest the linking note (the longest
/// shared folder), then the shallowest, then the first by path. A
/// markdown link is a path from the linking note's folder (`/` from the
/// root), percent-decoded; failing that it resolves as a `[[link]]` would.
///
/// Pure: no file system — the index hands in the list.
struct NoteLinks {
    let files: [String]
    private var byPath: [String: String] = [:]
    private var byName: [String: [String]] = [:]

    init(files: [String]) {
        self.files = files
        for file in files {
            byPath[Self.key(file)] = file
            byName[Self.key(Self.name(of: file)), default: []].append(file)
        }
    }

    static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    static func isNote(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    /// `Projects/Overterm.md` → `Overterm`; `shots/a.png` → `a.png`.
    static func name(of path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return isNote(last) ? String(last.dropLast(3)) : last
    }

    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// `a/./b/../c` → `a/c`; nil when it climbs out of the vault.
    static func normalize(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    static func join(_ folder: String, _ path: String) -> String { folder.isEmpty ? path : folder + "/" + path }

    // MARK: Resolving

    /// The file a link in the note at `source` points at; nil for a note
    /// not written yet. An empty target is `source` itself (`[[#Heading]]`).
    func resolve(_ link: NoteSyntax.Link, from source: String) -> String? {
        resolve(link.target, style: link.style, from: source)
    }

    func resolve(_ target: String, style: NoteSyntax.Link.Style, from source: String) -> String? {
        let target = target.trimmingCharacters(in: .whitespaces)
        if target.isEmpty { return source }
        if style == .markdown {
            let path = target.hasPrefix("/") ? Self.normalize(target) : Self.normalize(Self.join(Self.folder(of: source), target))
            if let path, let file = exact(path) { return file }
        }
        // 1 and 2: a path from the note's folder, then from the root.
        if let path = Self.normalize(Self.join(Self.folder(of: source), target)), let file = exact(path) { return file }
        if let path = Self.normalize(target), let file = exact(path) { return file }
        let parts = target.split(separator: "/").map(String.init)
        guard let last = parts.last else { return nil }
        // 3 and 4: by name, then by the path's tail.
        var candidates = byName[Self.key(Self.name(of: last))] ?? byName[Self.key(last)] ?? []
        if parts.count > 1 {
            let tail = Self.key(Self.normalize(target) ?? target)
            candidates = candidates.filter { file in
                let path = Self.key(file)
                let bare = Self.isNote(file) ? String(path.dropLast(3)) : path
                return [path, bare].contains { $0 == tail || $0.hasSuffix("/" + tail) }
            }
        }
        return nearest(candidates, to: source)
    }

    /// `path` or `path.md`, as it is in the vault.
    private func exact(_ path: String) -> String? {
        byPath[Self.key(path)] ?? byPath[Self.key(path + ".md")]
    }

    /// The candidate sharing the most folders with `source`, then the
    /// shallowest, then the first by path.
    private func nearest(_ candidates: [String], to source: String) -> String? {
        let here = Self.folder(of: source).split(separator: "/")
        func shared(_ file: String) -> Int {
            zip(Self.folder(of: file).split(separator: "/"), here).prefix { Self.key(String($0)) == Self.key(String($1)) }.count
        }
        return candidates.min { a, b in
            let (sa, sb) = (shared(a), shared(b))
            if sa != sb { return sa > sb }
            let (da, db) = (a.split(separator: "/").count, b.split(separator: "/").count)
            if da != db { return da < db }
            return a < b
        }
    }

    // MARK: Writing links

    /// What a `[[link]]` in `source` says to reach `file`: its name when no
    /// other file has it, else the shortest tail of its path that is
    /// unambiguous — and always what `resolve` reads back as `file`.
    func wikiTarget(to file: String, from source: String) -> String {
        let parts = file.split(separator: "/").map(String.init)
        let bare = Self.isNote(file) ? String(file.dropLast(3)) : file
        let bareParts = bare.split(separator: "/").map(String.init)
        for count in 1...max(1, bareParts.count) {
            let candidate = bareParts.suffix(count).joined(separator: "/")
            if resolve(candidate, style: .wiki, from: source) == file { return candidate }
        }
        return parts.isEmpty ? file : bare
    }

    /// A markdown link's destination from `source` to `file`: relative,
    /// percent-encoded where a link can't hold the character.
    static func markdownDestination(to file: String, from source: String) -> String {
        let here = folder(of: source).split(separator: "/").map(String.init)
        let there = file.split(separator: "/").map(String.init)
        var common = 0
        while common < here.count, common < there.count - 1, key(here[common]) == key(there[common]) { common += 1 }
        let path = Array(repeating: "..", count: here.count - common) + there[common...]
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        return path.joined(separator: "/").addingPercentEncoding(withAllowedCharacters: allowed) ?? path.joined(separator: "/")
    }

    // MARK: Renaming

    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
    }

    /// What renaming (or moving) `old` to `new` rewrites, by note — keyed by
    /// where each note is *after* the rename. A link that pointed at `old`
    /// points at `new`; any other link keeps pointing where it did, which a
    /// new name can otherwise steal (a second `Overterm.md`) and a moved
    /// note's relative links can lose. Edits come in text order; apply
    /// them from the last.
    static func renameEdits(old: String, new: String, files: [String], links: [String: [NoteSyntax.Link]]) -> [String: [Edit]] {
        let before = NoteLinks(files: files)
        let after = NoteLinks(files: files.map { key($0) == key(old) ? new : $0 })
        var result: [String: [Edit]] = [:]
        for (source, sourceLinks) in links {
            let moved = key(source) == key(old) ? new : source
            var edits: [Edit] = []
            for link in sourceLinks where !link.target.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let was = before.resolve(link, from: source) else { continue }
                let wanted = key(was) == key(old) ? new : was
                if let now = after.resolve(link, from: moved), key(now) == key(wanted) { continue }
                let replacement =
                    link.style == .wiki
                    ? after.wikiTarget(to: wanted, from: moved)
                    : markdownDestination(to: wanted, from: moved)
                edits.append(Edit(range: link.targetRange, replacement: replacement))
            }
            if !edits.isEmpty { result[moved] = edits.sorted { $0.range.location < $1.range.location } }
        }
        return result
    }

    /// `edits` applied to `text`, from the last.
    static func apply(_ edits: [Edit], to text: String) -> String {
        let out = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return out as String
    }
}
