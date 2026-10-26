import Foundation

/// What an agent's note tools reach: the window's notes, and what the page
/// has open — the window answers; tests hand in their own.
@MainActor
protocol AgentNotes: AnyObject {
    var notesWorkspace: NotesWorkspace { get }
    /// Open in the Notes page with unsaved edits: an agent's write would
    /// be lost to the next save, or lose them.
    func noteIsEditedHere(_ url: URL) -> Bool
    /// An agent wrote it: indexed now, reloaded where it is open.
    func noteWrittenByAgent(_ url: URL, text: String)
}

/// The notes' MCP tools, beside the browser's and the API client's on the
/// same server (BrowserBridge): an agent in Overterm finds what the user
/// wrote, reads it, writes a note or adds to today's — in the user's
/// vaults, through iCloud, never outside them.
@MainActor
enum NotesMCP {
    static func call(_ name: String, _ arguments: [String: Any], notes host: AgentNotes) async throws -> [String: Any] {
        let workspace = host.notesWorkspace
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func need(_ key: String) throws -> String {
            guard let value = string(key) else { throw BrowserMCP.ToolError(message: "\(name) needs “\(key)”.") }
            return value
        }
        if name == "notes_vaults" { return BrowserMCP.textResult(describeVaults(workspace)) }
        let vault = try pickVault(string("vault"), in: workspace)
        let index = await self.index(of: vault, in: workspace)

        switch name {
        case "notes_list":
            let folder = string("folder").flatMap(NoteLinks.normalize) ?? ""
            let paths = index.notes.map(\.path).filter { folder.isEmpty || $0.hasPrefix(folder + "/") }
            guard !paths.isEmpty else { return BrowserMCP.textResult("No notes\(folder.isEmpty ? "" : " in \(folder)") in “\(vault.name)”.") }
            let lines = paths.prefix(500).map { path -> String in
                let tags = index.entries[path]?.syntax?.allTags ?? []
                return tags.isEmpty ? path : path + "  " + tags.map { "#" + $0 }.joined(separator: " ")
            }
            return BrowserMCP.textResult(
                lines.joined(separator: "\n") + (paths.count > 500 ? "\n… and \(paths.count - 500) more (narrow with “folder”)." : ""))

        case "notes_search":
            let query = try need("query")
            let notes = index.entries.values.compactMap { entry -> (path: String, text: String, tags: [String])? in
                guard entry.isNote, let text = entry.text else { return nil }
                return (entry.path, text, entry.syntax?.allTags ?? [])
            }
            let results = NoteSearch.search(query, notes: notes, limit: (arguments["limit"] as? Int) ?? 30)
            guard !results.isEmpty else { return BrowserMCP.textResult("Nothing in “\(vault.name)” matches \(query).") }
            return BrowserMCP.textResult(
                results.map { result in
                    ([result.path] + result.hits.map { "  \($0.line): \($0.context)" }).joined(separator: "\n")
                }.joined(separator: "\n\n"))

        case "notes_read":
            let (path, url) = try existingNote(try need("path"), in: vault, index: index)
            let text = try await read(url, files: workspace.files)
            return BrowserMCP.textResult("\(path)\n\n\(text)")

        case "notes_backlinks":
            let (path, _) = try existingNote(try need("path"), in: vault, index: index)
            let backlinks = index.backlinks(to: path)
            guard !backlinks.isEmpty else { return BrowserMCP.textResult("No note links to \(path).") }
            return BrowserMCP.textResult(
                backlinks.map { backlink in
                    ([backlink.source] + backlink.links.map { "  " + index.context(of: $0, in: backlink.source) }).joined(separator: "\n")
                }.joined(separator: "\n\n"))

        case "notes_write":
            let text = arguments["text"] as? String ?? ""
            let mode = string("mode") ?? "create"
            guard ["create", "replace", "append"].contains(mode) else {
                throw BrowserMCP.ToolError(message: "notes_write's “mode” is create, replace or append.")
            }
            let (path, url) = try notePath(try need("path"), in: vault)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if mode == "create", exists {
                throw BrowserMCP.ToolError(message: "\(path) is there already: mode replace or append changes it.")
            }
            if host.noteIsEditedHere(url) {
                throw BrowserMCP.ToolError(message: "\(path) is open in Overterm with unsaved changes; ask the user to save it first.")
            }
            var written = text
            if mode == "append", exists {
                let current = try await read(url, files: workspace.files)
                written = current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + text
            }
            try await write(written, to: url, files: workspace.files)
            host.noteWrittenByAgent(url, text: written)
            return BrowserMCP.textResult("\(mode == "append" && exists ? "Added to" : exists ? "Replaced" : "Created") \(path) in “\(vault.name)”.")

        case "notes_daily":
            let text = try need("text")
            let config = vault.id == workspace.vault?.id ? workspace.config : VaultConfig.load(from: vault.url, files: workspace.files)
            let path = config.dailyNote(for: Date())
            let url = vault.url.appendingPathComponent(path)
            if host.noteIsEditedHere(url) {
                throw BrowserMCP.ToolError(message: "Today's note is open in Overterm with unsaved changes; ask the user to save it first.")
            }
            let exists = FileManager.default.fileExists(atPath: url.path)
            let current = exists ? try await read(url, files: workspace.files) : "# \(NoteLinks.name(of: path))\n\n"
            let written = current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + text + (text.hasSuffix("\n") ? "" : "\n")
            try await write(written, to: url, files: workspace.files)
            host.noteWrittenByAgent(url, text: written)
            return BrowserMCP.textResult("Added to today's note, \(path), in “\(vault.name)”.")

        default:
            throw BrowserMCP.ToolError(message: "Unknown tool: \(name)")
        }
    }

    // MARK: Vaults

    static func describeVaults(_ workspace: NotesWorkspace) -> String {
        let vaults = workspace.vaults.vaults
        guard !vaults.isEmpty else { return "No vaults yet: the user makes one in Notes (⌥⌘N)." }
        let current = workspace.vault?.id ?? workspace.vaults.current?.id
        return vaults.map { "\($0.id == current ? "* " : "  ")\($0.name) — \($0.path)\($0.isInICloudDrive ? " (iCloud Drive)" : "")" }
            .joined(separator: "\n")
    }

    /// The vault named (its name, case aside), else the one open in the
    /// page, else the last one open.
    static func pickVault(_ name: String?, in workspace: NotesWorkspace) throws -> Vault {
        if let name {
            guard let vault = workspace.vaults.vaults.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame })
            else { throw BrowserMCP.ToolError(message: "No vault “\(name)”. notes_vaults lists them.") }
            return vault
        }
        guard let vault = workspace.vault ?? workspace.vaults.current else {
            throw BrowserMCP.ToolError(message: "No vaults yet: the user makes one in Notes (⌥⌘N).")
        }
        return vault
    }

    /// The page's index for its vault; for another, one made for the call.
    static func index(of vault: Vault, in workspace: NotesWorkspace) async -> NoteIndex {
        if vault.id == workspace.vault?.id, let index = workspace.index {
            if !index.isReady { await index.refreshed() }
            return index
        }
        let index = NoteIndex(root: vault.url, files: workspace.files)
        await index.refreshed()
        return index
    }

    // MARK: Paths

    /// A note's path in the vault, from what an agent wrote: relative, not
    /// out of the vault, not into a hidden folder (`.overterm` is the
    /// vault's own), `.md` added when it has none.
    static func notePath(_ raw: String, in vault: Vault) throws -> (path: String, url: URL) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw BrowserMCP.ToolError(message: "“\(raw)”: a path in the vault, like Projects/Plan.md.")
        }
        guard let normalized = NoteLinks.normalize(trimmed), !normalized.isEmpty else {
            throw BrowserMCP.ToolError(message: "“\(raw)” leaves the vault.")
        }
        guard !normalized.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw BrowserMCP.ToolError(message: "“\(raw)”: hidden folders are the vault's own.")
        }
        let path = NoteLinks.isNote(normalized) ? normalized : normalized + ".md"
        let url = vault.url.appendingPathComponent(path)
        // Through a symlink that leads out of it, no.
        let root = vault.url.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root + "/") else { throw BrowserMCP.ToolError(message: "“\(raw)” leaves the vault.") }
        return (path, url)
    }

    /// A note there is: by its path, else by its name as a [[link]] would.
    static func existingNote(_ raw: String, in vault: Vault, index: NoteIndex) throws -> (path: String, url: URL) {
        if let found = try? notePath(raw, in: vault), index.entries[found.path] != nil || FileManager.default.fileExists(atPath: found.url.path) {
            return found
        }
        if let path = index.links.resolve(raw, style: .wiki, from: ""), NoteLinks.isNote(path) {
            return (path, vault.url.appendingPathComponent(path))
        }
        throw BrowserMCP.ToolError(message: "No note “\(raw)” in “\(vault.name)”. notes_search or notes_list finds it.")
    }

    // MARK: Off the main thread

    /// A note's text — downloaded first if it is only in iCloud, which
    /// blocks a second: not on the main thread.
    static func read(_ url: URL, files: CloudFiles) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try files.readText(url) })
            }
        }
    }

    static func write(_ text: String, to url: URL, files: CloudFiles) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try files.writeText(text, to: url) })
            }
        }
    }

    // MARK: Tools

    static let instructions =
        "The user's notes in Overterm: Markdown in their vaults, synced through iCloud. notes_search and notes_read find what they wrote; notes_write creates or changes a note, notes_daily adds to today's. Links are [[Note Name]], tags #tag."

    static let tools: [[String: Any]] = [
        tool("notes_vaults", "The user's vaults (folders of Markdown notes); * marks the one in use.", [:]),
        tool(
            "notes_list", "Every note in a vault, with its tags.",
            ["folder": ["type": "string", "description": "Only notes under this folder of the vault."], "vault": vaultArgument]),
        tool(
            "notes_search", "Finds notes by their words: every term must be in the note; \"a phrase\" in quotes; #tag for a tag. Lists the lines that match.",
            ["query": ["type": "string"], "limit": ["type": "integer", "description": "At most this many notes (30)."], "vault": vaultArgument],
            required: ["query"]),
        tool(
            "notes_read", "A note's text.",
            ["path": ["type": "string", "description": "Its path in the vault (Projects/Plan.md), or its name (Plan)."], "vault": vaultArgument],
            required: ["path"]),
        tool(
            "notes_backlinks", "The notes that link to a note, with the line each link is on.",
            ["path": ["type": "string", "description": "Its path in the vault, or its name."], "vault": vaultArgument], required: ["path"]),
        tool(
            "notes_write",
            "Writes a note: mode create (the default; fails if it exists), replace (its whole text), append (to its end). Paths are in the vault; .md is added.",
            [
                "path": ["type": "string", "description": "Like Projects/Plan.md."], "text": ["type": "string", "description": "Markdown."],
                "mode": ["type": "string", "enum": ["create", "replace", "append"]], "vault": vaultArgument,
            ], required: ["path", "text"]),
        tool(
            "notes_daily", "Adds to today's daily note (made if it isn't there).",
            ["text": ["type": "string", "description": "Markdown, added at its end."], "vault": vaultArgument], required: ["text"]),
    ]

    private static let vaultArgument: [String: Any] = ["type": "string", "description": "A vault's name (notes_vaults); the one in use if left out."]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }
}
