import Foundation

/// Searching a vault's notes, over the text the index keeps (no git, no
/// grep: a vault is not a checkout). Pure.
///
/// Every term must be in the note — its text or its name — ignoring case
/// and accents ("cagri" finds "çağrı": the dotless ı is no accented i to
/// Foundation, so it is folded first); "a phrase" in quotes is one term;
/// `#tag` asks for the tag (or one under it) instead of the text.
enum NoteSearch {
    struct Hit: Equatable {
        /// The match, in the note's text (UTF-16).
        var range: NSRange
        /// 1-based.
        var line: Int
        /// The line it is on, trimmed.
        var context: String
    }

    struct Result: Equatable {
        var path: String
        var hits: [Hit]
        /// A term is in the note's name.
        var nameMatches: Bool
    }

    struct Query: Equatable {
        var words: [String] = []
        var tags: [String] = []
        var isEmpty: Bool { words.isEmpty && tags.isEmpty }
    }

    static func parse(_ query: String) -> Query {
        var result = Query()
        var current = ""
        var quoted = false
        func flush() {
            let term = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !term.isEmpty else { return }
            if !quoted, term.hasPrefix("#"), term.count > 1 { result.tags.append(String(term.dropFirst()).lowercased()) } else { result.words.append(term) }
        }
        for character in query {
            if character == "\"" {
                flush()
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// ı and İ as i and I — one UTF-16 unit for one, so a range found in
    /// the folded text is the same range in the note.
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
    }

    /// The notes matching `query`, best first: a term in the name, then the
    /// most hits, then by path. At most `hitsPerNote` lines each.
    static func search(
        _ query: String, notes: [(path: String, text: String, tags: [String])], limit: Int = 200, hitsPerNote: Int = 5
    ) -> [Result] {
        var parsed = parse(query)
        guard !parsed.isEmpty else { return [] }
        parsed.words = parsed.words.map(fold)
        var results: [Result] = []
        for note in notes {
            let tags = note.tags.map { $0.lowercased() }
            guard parsed.tags.allSatisfy({ wanted in tags.contains { $0 == wanted || $0.hasPrefix(wanted + "/") } }) else { continue }
            let name = fold(NoteLinks.name(of: note.path))
            let text = fold(note.text)
            guard parsed.words.allSatisfy({ text.range(of: $0, options: options) != nil || name.range(of: $0, options: options) != nil })
            else { continue }
            let nameMatches = parsed.words.contains { name.range(of: $0, options: options) != nil }
            results.append(
                Result(path: note.path, hits: hits(of: parsed.words, in: note.text, folded: text, limit: hitsPerNote), nameMatches: nameMatches))
        }
        results.sort {
            if $0.nameMatches != $1.nameMatches { return $0.nameMatches }
            if $0.hits.count != $1.hits.count { return $0.hits.count > $1.hits.count }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return Array(results.prefix(limit))
    }

    /// Where the words are in `text` (found in its `folded` copy), a line
    /// once, in order.
    static func hits(of words: [String], in text: String, folded: String, limit: Int) -> [Hit] {
        let ns = text as NSString
        let haystack = folded as NSString
        var found: [NSRange] = []
        for word in words {
            var from = 0
            while from < ns.length {
                let range = haystack.range(of: word, options: options, range: NSRange(location: from, length: ns.length - from))
                guard range.location != NSNotFound else { break }
                found.append(range)
                from = NSMaxRange(range)
            }
        }
        found.sort { $0.location < $1.location }
        var hits: [Hit] = []
        var lines = Set<Int>()
        for range in found {
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            guard lines.insert(lineRange.location).inserted else { continue }
            let line = ns.substring(to: range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            hits.append(Hit(range: range, line: line, context: ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)))
            if hits.count == limit { break }
        }
        return hits
    }
}
