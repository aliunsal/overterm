import Foundation

/// `[[` in a note: which notes to offer while the link's name is being
/// typed, and what choosing one writes. Pure.
enum NoteCompletion {
    struct Context: Equatable {
        /// Just after the `[[`.
        var anchor: Int
        /// What is typed between the `[[` and the caret.
        var query: String
        /// `]]` already follows the caret (the editor pairs brackets).
        var isClosed: Bool
        /// `![[`: any file, not only notes.
        var isEmbed: Bool
    }

    struct Suggestion: Equatable {
        var title: String
        /// Replaces the query (and a `]]` after it): the target, `]]` added.
        var insert: String
        var detail: String
        var matched: [Int] = []
    }

    /// The caret inside a `[[` still open on its line — before a `|` or a
    /// `#`, where a name goes.
    static func context(in text: NSString, caret: Int) -> Context? {
        guard caret <= text.length else { return nil }
        var i = caret
        var anchor: Int?
        while i >= 2 {
            let c = text.character(at: i - 1)
            if c == 0x0A || c == 0x0D { return nil }
            if c == 0x5D, text.character(at: i - 2) == 0x5D { return nil }  // ]]
            if c == 0x5B, text.character(at: i - 2) == 0x5B {  // [[
                anchor = i
                break
            }
            i -= 1
        }
        guard let anchor else { return nil }
        let query = text.substring(with: NSRange(location: anchor, length: caret - anchor))
        if query.contains(where: { "|#[]".contains($0) }) { return nil }
        let isClosed = caret + 2 <= text.length && text.substring(with: NSRange(location: caret, length: 2)) == "]]"
        let isEmbed = anchor >= 3 && text.character(at: anchor - 3) == 0x21
        return Context(anchor: anchor, query: query, isClosed: isClosed, isEmbed: isEmbed)
    }

    /// The notes (or, for an embed, files) for `query`, best first: by
    /// name, then by alias (writing `[[target|alias]]`). An empty query
    /// lists them by name.
    static func suggestions(
        for context: Context, files: [String], aliases: [String: [String]], links: NoteLinks, from source: String, limit: Int = 50
    ) -> [Suggestion] {
        let query = context.query.trimmingCharacters(in: .whitespaces)
        var scored: [(score: Int, suggestion: Suggestion)] = []
        for path in files where path != source && (context.isEmbed || NoteLinks.isNote(path)) {
            let name = NoteLinks.name(of: path)
            let folder = NoteLinks.folder(of: path)
            let target = links.wikiTarget(to: path, from: source)
            if query.isEmpty {
                scored.append((0, Suggestion(title: name, insert: target + "]]", detail: folder)))
            } else if let match = CompletionMatch.score(candidate: name, query: query) {
                scored.append((match.score + 4, Suggestion(title: name, insert: target + "]]", detail: folder, matched: match.matched)))
            }
            for alias in aliases[path] ?? [] where !query.isEmpty {
                guard let match = CompletionMatch.score(candidate: alias, query: query) else { continue }
                scored.append((match.score, Suggestion(title: alias, insert: "\(target)|\(alias)]]", detail: "→ \(name)", matched: match.matched)))
            }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.suggestion.title.count != $1.suggestion.title.count { return $0.suggestion.title.count < $1.suggestion.title.count }
            return $0.suggestion.title.localizedStandardCompare($1.suggestion.title) == .orderedAscending
        }
        return scored.prefix(limit).map(\.suggestion)
    }
}
