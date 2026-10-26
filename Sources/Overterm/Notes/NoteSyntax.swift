import Foundation

/// What a note says beyond CommonMark: Obsidian's syntax, kept as it is so
/// the notes stay portable — `[[links]]`, `![[embeds]]`, `#tags`, YAML
/// frontmatter, `- [ ]` tasks, `==highlights==`, `%%comments%%`,
/// `> [!callouts]` — and the plain `[text](note.md)` links and the headings
/// the index needs.
///
/// Pure: read off the text alone. Ranges are UTF-16, the editor's
/// `NSString`. Nothing inside code — a fenced block or a `span` — or inside
/// a comment counts; neither tree-sitter's `markdown_inline` nor
/// `AttributedString(markdown:)` knows any of this.
struct NoteSyntax: Equatable, Sendable {
    struct Link: Equatable, Sendable {
        enum Style: Equatable, Sendable { case wiki, markdown }
        /// The whole link: brackets, parentheses and an embed's `!`.
        var range: NSRange
        /// What it points at as written, without the heading: a note's name
        /// or path, a file. Empty for `[[#Heading]]`, this note. A markdown
        /// link's is percent-decoded.
        var target: String
        /// Where `target` is in the text, as written: what a rename rewrites.
        var targetRange: NSRange
        var heading: String?
        /// `[[Note#^id]]`'s `id`.
        var block: String?
        /// `[[Note|alias]]`, or a markdown link's text.
        var alias: String?
        var isEmbed: Bool
        var style: Style
    }

    struct Tag: Equatable, Sendable {
        var range: NSRange
        /// Without the `#`, as written: `project/overterm`.
        var name: String
    }

    struct Heading: Equatable, Sendable {
        /// The whole line.
        var range: NSRange
        var level: Int
        var text: String
    }

    struct Task: Equatable, Sendable {
        /// The `[ ]` box.
        var range: NSRange
        var isDone: Bool
    }

    struct Callout: Equatable, Sendable {
        /// The `[!type]` marker.
        var range: NSRange
        /// Lowercased: `note`, `warning`.
        var type: String
        var title: String
    }

    struct Frontmatter: Equatable, Sendable {
        struct Field: Equatable, Sendable {
            var key: String
            /// As written; a list's items joined with ", ".
            var value: String
        }

        /// The opening `---` through the closing line and its newline.
        var range: NSRange
        var tags: [String] = []
        var aliases: [String] = []
        var fields: [Field] = []
    }

    var frontmatter: Frontmatter?
    var links: [Link] = []
    var tags: [Tag] = []
    var headings: [Heading] = []
    var tasks: [Task] = []
    var callouts: [Callout] = []
    var highlights: [NSRange] = []
    var comments: [NSRange] = []
    /// Fenced blocks and inline spans.
    var code: [NSRange] = []

    /// The frontmatter's tags and the text's, each once (case aside), in
    /// the order they first appear.
    var allTags: [String] {
        var seen = Set<String>()
        return ((frontmatter?.tags ?? []) + tags.map(\.name)).filter { seen.insert($0.lowercased()).inserted }
    }

    static func parse(_ text: String) -> NoteSyntax {
        var parser = Parser(Array(text.utf16))
        return parser.run()
    }
}

// MARK: - Parsing

private struct Parser {
    let u: [unichar]
    var out = NoteSyntax()
    /// An open `%%`: where it began, until its closing `%%`, lines later.
    var commentStart: Int?

    init(_ u: [unichar]) { self.u = u }

    // Characters, by their UTF-16 code.
    static let newline: unichar = 0x0A, cr: unichar = 0x0D, space: unichar = 0x20, tab: unichar = 0x09
    static let hash: unichar = 0x23, bang: unichar = 0x21, open: unichar = 0x5B, close: unichar = 0x5D
    static let paren: unichar = 0x28, closeParen: unichar = 0x29, pipe: unichar = 0x7C, backslash: unichar = 0x5C
    static let backtick: unichar = 0x60, tilde: unichar = 0x7E, percent: unichar = 0x25, equals: unichar = 0x3D
    static let caret: unichar = 0x5E, gt: unichar = 0x3E, lt: unichar = 0x3C, dash: unichar = 0x2D

    func string(_ range: Range<Int>) -> String { String(utf16CodeUnits: Array(u[range]), count: range.count) }
    func ns(_ range: Range<Int>) -> NSRange { NSRange(location: range.lowerBound, length: range.count) }
    func isBlank(_ c: unichar) -> Bool { c == Self.space || c == Self.tab }

    /// Each line's start and end (without its line break), and where the next begins.
    func lines() -> [(start: Int, end: Int, next: Int)] {
        var result: [(Int, Int, Int)] = []
        var start = 0
        var i = 0
        while i < u.count {
            if u[i] == Self.newline {
                let end = i > start && u[i - 1] == Self.cr ? i - 1 : i
                result.append((start, end, i + 1))
                start = i + 1
            }
            i += 1
        }
        if start < u.count { result.append((start, u.count, u.count)) }
        return result
    }

    mutating func run() -> NoteSyntax {
        let lines = lines()
        var index = 0
        if let (frontmatter, after) = frontmatter(lines) {
            out.frontmatter = frontmatter
            index = after
        }
        // An open fence: its character, its length, where it began.
        var fence: (char: unichar, count: Int, start: Int)?
        while index < lines.count {
            let line = lines[index]
            index += 1
            if let open = fence {
                if closesFence(line, open.char, open.count) {
                    out.code.append(ns(open.start..<line.end))
                    fence = nil
                }
                continue
            }
            if commentStart == nil, let opened = opensFence(line) {
                fence = (opened.char, opened.count, line.start)
                continue
            }
            if commentStart == nil { blockSyntax(line) }
            inline(line.start, line.end)
        }
        if let open = fence { out.code.append(ns(open.start..<u.count)) }
        // An unclosed comment runs to the end, as Obsidian draws it.
        if let start = commentStart { out.comments.append(ns(start..<u.count)) }
        return out
    }

    // MARK: Frontmatter

    func isRule(_ line: (start: Int, end: Int, next: Int), _ char: unichar) -> Bool {
        var end = line.end
        while end > line.start, isBlank(u[end - 1]) { end -= 1 }
        return end - line.start == 3 && u[line.start..<end].allSatisfy { $0 == char }
    }

    /// `---` on the first line, through the next `---` (or `...`).
    func frontmatter(_ lines: [(start: Int, end: Int, next: Int)]) -> (NoteSyntax.Frontmatter, Int)? {
        guard let first = lines.first, isRule(first, Self.dash) else { return nil }
        guard let closing = lines.indices.dropFirst().first(where: { isRule(lines[$0], Self.dash) || isRule(lines[$0], 0x2E) })
        else { return nil }
        var frontmatter = NoteSyntax.Frontmatter(range: ns(0..<lines[closing].next))
        let body = lines[1..<closing].map { string($0.start..<$0.end) }
        var i = 0
        while i < body.count {
            let line = body[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var items: [String]
            if rest.isEmpty {
                // A block list: the indented `- item` lines after it.
                items = []
                while i < body.count {
                    let item = body[i].trimmingCharacters(in: .whitespaces)
                    if item.hasPrefix("- ") || item == "-" {
                        items.append(Self.unquote(String(item.dropFirst()).trimmingCharacters(in: .whitespaces)))
                        i += 1
                    } else if item.isEmpty {
                        i += 1
                    } else {
                        break
                    }
                }
            } else if rest.hasPrefix("["), rest.hasSuffix("]") {
                items = rest.dropFirst().dropLast().split(separator: ",").map {
                    Self.unquote($0.trimmingCharacters(in: .whitespaces))
                }
            } else {
                items = [Self.unquote(rest)]
            }
            items = items.filter { !$0.isEmpty }
            frontmatter.fields.append(.init(key: key, value: items.joined(separator: ", ")))
            switch key.lowercased() {
            case "tags", "tag":
                // `tags: a, b` and `tags: a b` are old forms Obsidian still reads.
                let split = items.count == 1 ? items[0].split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) : items
                frontmatter.tags += split.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
            case "aliases", "alias":
                frontmatter.aliases +=
                    items.count == 1 && key.lowercased() == "aliases" && !rest.hasPrefix("[") && !rest.isEmpty
                    ? items[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    : items
            default: break
            }
        }
        return (frontmatter, closing + 1)
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, first == "\"" || first == "'", s.last == first else { return s }
        return String(s.dropFirst().dropLast())
    }

    // MARK: Fences

    /// Up to three spaces, then three or more backticks or tildes.
    func opensFence(_ line: (start: Int, end: Int, next: Int)) -> (char: unichar, count: Int)? {
        var i = line.start
        while i < line.end, i - line.start < 3, u[i] == Self.space { i += 1 }
        guard i < line.end, u[i] == Self.backtick || u[i] == Self.tilde else { return nil }
        let char = u[i]
        var count = 0
        while i < line.end, u[i] == char {
            count += 1
            i += 1
        }
        guard count >= 3 else { return nil }
        // A backtick fence's info string has no backtick in it.
        if char == Self.backtick, u[i..<line.end].contains(Self.backtick) { return nil }
        return (char, count)
    }

    func closesFence(_ line: (start: Int, end: Int, next: Int), _ char: unichar, _ count: Int) -> Bool {
        var i = line.start
        while i < line.end, i - line.start < 3, u[i] == Self.space { i += 1 }
        var run = 0
        while i < line.end, u[i] == char {
            run += 1
            i += 1
        }
        return run >= count && u[i..<line.end].allSatisfy(isBlank)
    }

    // MARK: Lines: headings, callouts, tasks

    mutating func blockSyntax(_ line: (start: Int, end: Int, next: Int)) {
        var i = line.start
        while i < line.end, i - line.start < 3, u[i] == Self.space { i += 1 }
        guard i < line.end else { return }

        if u[i] == Self.hash {
            var level = 0
            var j = i
            while j < line.end, u[j] == Self.hash {
                level += 1
                j += 1
            }
            if level <= 6, j == line.end || isBlank(u[j]) {
                var text = string(j..<line.end).trimmingCharacters(in: .whitespaces)
                // A closing run of #s is not part of it.
                if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
                if text.allSatisfy({ $0 == "#" }) { text = "" }
                out.headings.append(.init(range: ns(line.start..<line.end), level: level, text: text))
                return
            }
        }

        if u[i] == Self.gt {
            var j = i + 1
            while j < line.end, isBlank(u[j]) { j += 1 }
            if j + 2 < line.end, u[j] == Self.open, u[j + 1] == Self.bang, let end = u[j..<line.end].firstIndex(of: Self.close) {
                let type = string(j + 2..<end)
                if !type.isEmpty, type.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                    var k = end + 1
                    if k < line.end, u[k] == 0x2B || u[k] == Self.dash { k += 1 }  // + or -: folded
                    out.callouts.append(
                        .init(
                            range: ns(j..<end + 1), type: type.lowercased(),
                            title: string(k..<line.end).trimmingCharacters(in: .whitespaces)))
                }
            }
            return
        }

        // - [ ] / * [x] / 1. [ ]: the marker, one space, a box.
        var j = line.start
        while j < line.end, isBlank(u[j]) { j += 1 }
        guard j < line.end else { return }
        if u[j] == Self.dash || u[j] == 0x2A || u[j] == 0x2B {
            j += 1
        } else {
            let digits = j
            while j < line.end, (0x30...0x39).contains(u[j]) { j += 1 }
            guard j > digits, j < line.end, u[j] == 0x2E || u[j] == Self.closeParen else { return }
            j += 1
        }
        guard j + 3 <= line.end, u[j] == Self.space, u[j + 1] == Self.open, u[j + 3] == Self.close,
            j + 4 == line.end || isBlank(u[j + 4])
        else { return }
        out.tasks.append(.init(range: ns(j + 1..<j + 4), isDone: u[j + 2] != Self.space))
    }

    // MARK: Inline

    mutating func inline(_ start: Int, _ end: Int) {
        var i = start
        /// Where an open `==` closes, so the closing pair opens nothing.
        var highlightClose: Int?
        while i < end {
            if let open = commentStart {
                guard let close = find([Self.percent, Self.percent], from: i, to: end) else { return }
                out.comments.append(ns(open..<close + 2))
                commentStart = nil
                i = close + 2
                continue
            }
            let c = u[i]
            let next: unichar? = i + 1 < end ? u[i + 1] : nil
            switch c {
            case Self.backslash:
                i += 2
            case Self.backtick:
                var n = 0
                while i + n < end, u[i + n] == Self.backtick { n += 1 }
                if let close = closingRun(of: n, from: i + n, to: end) {
                    out.code.append(ns(i..<close + n))
                    i = close + n
                } else {
                    i += n
                }
            case Self.percent where next == Self.percent:
                commentStart = i
                i += 2
            case Self.bang where next == Self.open:
                if let link = i + 2 < end && u[i + 2] == Self.open ? wikilink(at: i + 1, end, embed: true) : markdownLink(at: i + 1, end, embed: true) {
                    i = link
                } else {
                    i += 1
                }
            case Self.open:
                if let link = next == Self.open ? wikilink(at: i, end, embed: false) : markdownLink(at: i, end, embed: false) {
                    i = link
                } else {
                    i += 1
                }
            case Self.equals where next == Self.equals:
                if highlightClose == i {
                    highlightClose = nil
                } else if let close = find([Self.equals, Self.equals], from: i + 2, to: end), close > i + 2 {
                    out.highlights.append(ns(i..<close + 2))
                    highlightClose = close
                }
                i += 2
            case Self.hash where i == start || isBlank(u[i - 1]):
                i = tag(at: i, end)
            default:
                i += 1
            }
        }
    }

    func find(_ needle: [unichar], from: Int, to end: Int) -> Int? {
        guard needle.count <= end - from else { return nil }
        var i = from
        while i + needle.count <= end {
            if u[i] == needle[0], Array(u[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// A run of exactly `n` backticks: a code span's end.
    func closingRun(of n: Int, from: Int, to end: Int) -> Int? {
        var i = from
        while i < end {
            guard u[i] == Self.backtick else {
                i += 1
                continue
            }
            var run = 0
            while i + run < end, u[i + run] == Self.backtick { run += 1 }
            if run == n { return i }
            i += run
        }
        return nil
    }

    /// `[[target#heading|alias]]` with its first `[` at `s`; where scanning goes on.
    mutating func wikilink(at s: Int, _ end: Int, embed: Bool) -> Int? {
        guard let close = find([Self.close, Self.close], from: s + 2, to: end), close > s + 2 else { return nil }
        let inner = s + 2..<close
        if find([Self.open, Self.open], from: inner.lowerBound, to: inner.upperBound) != nil { return nil }
        // The alias: after the first |, or \| inside a table.
        var bar: Int?
        var targetEnd = close
        for k in inner where u[k] == Self.pipe {
            bar = k
            targetEnd = k > inner.lowerBound && u[k - 1] == Self.backslash ? k - 1 : k
            break
        }
        let hash = u[inner.lowerBound..<targetEnd].firstIndex(of: Self.hash)
        let rawTarget = inner.lowerBound..<(hash ?? targetEnd)
        let (target, targetRange) = trimmed(rawTarget)
        var heading: String?
        var block: String?
        if let hash {
            let rest = string(hash + 1..<targetEnd).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("^") { block = String(rest.dropFirst()) } else if !rest.isEmpty { heading = rest }
        }
        let alias = bar.map { string($0 + 1..<close).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        if target.isEmpty && heading == nil && block == nil { return nil }
        out.links.append(
            .init(
                range: ns((embed ? s - 1 : s)..<close + 2), target: target, targetRange: ns(targetRange), heading: heading,
                block: block, alias: alias, isEmbed: embed, style: .wiki))
        return close + 2
    }

    /// `[text](destination "title")` with its `[` at `s`. A link to a URL is
    /// stepped over whole (a `#` in it is no tag), and not recorded.
    mutating func markdownLink(at s: Int, _ end: Int, embed: Bool) -> Int? {
        var depth = 0
        var k = s
        var textEnd: Int?
        while k < end {
            if u[k] == Self.backslash {
                k += 2
                continue
            }
            if u[k] == Self.open { depth += 1 }
            if u[k] == Self.close {
                depth -= 1
                if depth == 0 {
                    textEnd = k
                    break
                }
            }
            k += 1
        }
        guard let textEnd, textEnd + 1 < end, u[textEnd + 1] == Self.paren else { return nil }
        var d = textEnd + 2
        while d < end, isBlank(u[d]) { d += 1 }
        let destination: Range<Int>
        var after: Int
        if d < end, u[d] == Self.lt {
            guard let gt = u[d..<end].firstIndex(of: Self.gt) else { return nil }
            destination = d + 1..<gt
            after = gt + 1
        } else {
            var parens = 0
            var e = d
            while e < end, !isBlank(u[e]) {
                if u[e] == Self.paren { parens += 1 }
                if u[e] == Self.closeParen {
                    if parens == 0 { break }
                    parens -= 1
                }
                e += 1
            }
            destination = d..<e
            after = e
        }
        // An optional title, then the closing parenthesis.
        guard let closeParen = u[after..<end].firstIndex(of: Self.closeParen) else { return nil }
        after = closeParen + 1
        let raw = string(destination)
        if raw.isEmpty || raw.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil { return after }

        let hash = u[destination].firstIndex(of: Self.hash)
        let targetRange = destination.lowerBound..<(hash ?? destination.upperBound)
        let target = string(targetRange).removingPercentEncoding ?? string(targetRange)
        let heading = hash.map { string($0 + 1..<destination.upperBound) }.map { $0.removingPercentEncoding ?? $0 }
        let text = string(s + 1..<textEnd).trimmingCharacters(in: .whitespaces)
        out.links.append(
            .init(
                range: ns((embed ? s - 1 : s)..<after), target: target, targetRange: ns(targetRange),
                heading: heading.flatMap { $0.hasPrefix("^") || $0.isEmpty ? nil : $0 },
                block: heading.flatMap { $0.hasPrefix("^") ? String($0.dropFirst()) : nil }, alias: text.isEmpty ? nil : text,
                isEmbed: embed, style: .markdown))
        return after
    }

    func trimmed(_ range: Range<Int>) -> (String, Range<Int>) {
        var a = range.lowerBound
        var b = range.upperBound
        while a < b, isBlank(u[a]) { a += 1 }
        while b > a, isBlank(u[b - 1]) { b -= 1 }
        return (string(a..<b), a..<b)
    }

    static let tagCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-/"))

    /// `#name` with its `#` at `s`: letters, digits, `_`, `-`, `/`, and not
    /// only digits (`#1` is no tag). Where scanning goes on.
    mutating func tag(at s: Int, _ end: Int) -> Int {
        var k = s + 1
        while k < end, let scalar = Unicode.Scalar(u[k]), Self.tagCharacters.contains(scalar) { k += 1 }
        let name = string(s + 1..<k)
        guard !name.isEmpty, !name.allSatisfy(\.isNumber) else { return s + 1 }
        out.tags.append(.init(range: ns(s..<k), name: name))
        return k
    }
}
