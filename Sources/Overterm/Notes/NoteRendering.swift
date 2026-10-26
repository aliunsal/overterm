import Foundation

/// A note as the preview renders it: Obsidian's syntax turned into what
/// `AttributedString(markdown:)` knows, before MarkdownRenderer draws it.
/// Pure.
///
/// - `[[Note#Heading|alias]]` → a link to `overterm-note:Note#Heading`
///   reading "alias" (or "Note › Heading"); an embed the same.
/// - `#tag` → a link to `overterm-tag:tag`.
/// - `%%comments%%` and the frontmatter go: Obsidian's reading view hides
///   them.
/// - A single line break is a line break, as Obsidian draws one by default
///   (Markdown would join the lines into one paragraph).
///
/// Nothing in code changes.
enum NoteRendering {
    static let noteScheme = "overterm-note"
    static let tagScheme = "overterm-tag"
    /// `![[shot.png]]`: an image, drawn in place by the preview's host.
    static let embedScheme = "overterm-embed"

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"]

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func markdown(_ text: String, syntax given: NoteSyntax? = nil) -> String {
        let syntax = given ?? NoteSyntax.parse(text)
        let ns = text as NSString
        var edits: [(range: NSRange, text: String)] = []
        if let frontmatter = syntax.frontmatter { edits.append((frontmatter.range, "")) }
        for link in syntax.links where link.style == .wiki {
            if link.isEmbed, isImage(link.target) {
                edits.append((link.range, "[\(escape(link.alias ?? link.target))](\(embedScheme):\(encode(link.target)))"))
                continue
            }
            edits.append((link.range, "[\(escape(link.alias ?? title(of: link)))](\(url(of: link)))"))
        }
        for tag in syntax.tags {
            edits.append((tag.range, "[#\(escape(tag.name))](\(tagScheme):\(encode(tag.name)))"))
        }
        for comment in syntax.comments { edits.append((comment, "")) }
        for position in softBreaks(in: ns, syntax: syntax) { edits.append((NSRange(location: position, length: 0), "  ")) }

        let out = NSMutableString(string: text)
        // From the end, so each range is still where it was.
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: edit.range, with: edit.text)
        }
        return out as String
    }

    /// What a link without an alias reads as: the note's name, then the
    /// heading — `[[Plan#Steps]]` is "Plan › Steps", `[[#Steps]]` "Steps".
    static func title(of link: NoteSyntax.Link) -> String {
        let name = link.target.isEmpty ? "" : NoteLinks.name(of: link.target)
        let part = link.heading ?? link.block.map { "^" + $0 }
        switch (name.isEmpty, part) {
        case (true, let part?): return part
        case (false, let part?): return "\(name) › \(part)"
        default: return name
        }
    }

    /// `overterm-note:Projects/Plan#Steps`: the target as written, the
    /// heading (or `^block`) as the fragment.
    static func url(of link: NoteSyntax.Link) -> String {
        let fragment = link.heading ?? link.block.map { "^" + $0 }
        return "\(noteScheme):\(encode(link.target))" + (fragment.map { "#" + encode($0) } ?? "")
    }

    /// A clicked note link back: its target and heading (or `^block`).
    static func target(of url: URL) -> (target: String, heading: String?)? {
        guard url.scheme == noteScheme else { return nil }
        let raw = url.absoluteString.dropFirst(noteScheme.count + 1)
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let heading = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        return (target, heading)
    }

    static func embed(of url: URL) -> String? {
        guard url.scheme == embedScheme else { return nil }
        let raw = String(url.absoluteString.dropFirst(embedScheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }

    static func tag(of url: URL) -> String? {
        guard url.scheme == tagScheme else { return nil }
        let raw = String(url.absoluteString.dropFirst(tagScheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))

    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

    /// Link text: brackets and backslashes escaped.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: Line breaks

    /// Where a line ends inside a paragraph — the next line goes on with
    /// it — so two spaces there make Markdown break the line.
    static func softBreaks(in text: NSString, syntax: NoteSyntax) -> [Int] {
        var lines: [NSRange] = []
        var start = 0
        while start < text.length {
            let line = text.lineRange(for: NSRange(location: start, length: 0))
            lines.append(line)
            start = NSMaxRange(line)
        }
        let hidden = syntax.code + syntax.comments + (syntax.frontmatter.map { [$0.range] } ?? [])
        func isHidden(_ position: Int) -> Bool { hidden.contains { NSLocationInRange(position, $0) } }
        var result: [Int] = []
        for (i, line) in lines.enumerated() where i + 1 < lines.count {
            let content = contentEnd(of: line, in: text)
            guard content < NSMaxRange(line), !isHidden(content), !isHidden(lines[i + 1].location) else { continue }
            let this = text.substring(with: NSRange(location: line.location, length: content - line.location))
            let next = text.substring(with: lines[i + 1]).trimmingCharacters(in: .newlines)
            guard isParagraphText(this), !next.trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(next) else { continue }
            // Already a hard break: two spaces or a backslash at its end.
            if this.hasSuffix("  ") || this.hasSuffix("\\") { continue }
            result.append(content)
        }
        return result
    }

    private static func contentEnd(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    /// A line that is a paragraph's: not blank, not a heading, a table row
    /// or a rule.
    private static func isParagraphText(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("|") { return false }
        if trimmed.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) != nil { return false }
        if trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// A line that begins a block of its own: a heading, a list item, a
    /// quote, a table row, a fence, a rule.
    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"^#{1,6}(\s|$)"#, #"^[-*+]\s"#, #"^\d+[.)]\s"#, "^>", #"^\|"#, "^```", "^~~~", #"^([-*_])(\s*\1){2,}$"#, "^=+$",
        ]
        return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
    }
}
