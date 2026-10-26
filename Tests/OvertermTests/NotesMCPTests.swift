import XCTest

@testable import Overterm

/// What answers an agent's note tools here: a workspace on temporary
/// vaults, and the notes "open with edits" a test says.
@MainActor
private final class Host: AgentNotes {
    let notesWorkspace: NotesWorkspace
    var editedHere: Set<String> = []
    private(set) var written: [String] = []

    init(_ workspace: NotesWorkspace) { notesWorkspace = workspace }

    func noteIsEditedHere(_ url: URL) -> Bool { editedHere.contains(url.lastPathComponent) }
    func noteWrittenByAgent(_ url: URL, text: String) { written.append(url.lastPathComponent) }
}

/// The notes' MCP tools, as an agent calls them — iCloud played by
/// SimulatedCloudFiles.
@MainActor
final class NotesMCPTests: XCTestCase {
    private var dir: URL!
    private var host: Host!
    private var vault: URL { dir.appendingPathComponent("Main") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-mcp-\(UUID().uuidString)", isDirectory: true)
        let workspace = NotesWorkspace(vaults: NoteVaults(url: dir.appendingPathComponent("vaults.json")), files: SimulatedCloudFiles())
        try workspace.addVault(at: vault)
        try write("Inbox.md", "# Inbox\n\nCall the bank about [[Plan]]. #todo\n")
        try write("Projects/Plan.md", "# Plan\n\nSteps.\n")
        try write(".overterm/notes.json", "{}")
        try workspace.addVault(at: dir.appendingPathComponent("Other"))
        try "# Elsewhere\n".write(to: dir.appendingPathComponent("Other/Elsewhere.md"), atomically: true, encoding: .utf8)
        workspace.activate(workspace.vaults.vaults[0])
        host = Host(workspace)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = vault.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let result = try await NotesMCP.call(name, arguments, notes: host)
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func refusal(_ name: String, _ arguments: [String: Any]) async -> String? {
        do {
            _ = try await NotesMCP.call(name, arguments, notes: host)
            return nil
        } catch let error as BrowserMCP.ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    func testFindingAndReading() async throws {
        let vaults = try await call("notes_vaults")
        XCTAssertTrue(vaults.contains("* Main"), vaults)
        XCTAssertTrue(vaults.contains("  Other"), vaults)
        let answer1 = try await call("notes_list")
        XCTAssertEqual(answer1, "Inbox.md  #todo\nProjects/Plan.md")
        let found = try await call("notes_search", ["query": "bank"])
        XCTAssertEqual(found, "Inbox.md\n  3: Call the bank about [[Plan]]. #todo")
        let read = try await call("notes_read", ["path": "Plan"])
        XCTAssertTrue(read.hasPrefix("Projects/Plan.md\n\n# Plan"), "by name, as a link would")
        let backlinks = try await call("notes_backlinks", ["path": "Projects/Plan.md"])
        XCTAssertEqual(backlinks, "Inbox.md\n  Call the bank about [[Plan]]. #todo")
        let answer2 = try await call("notes_list", ["vault": "other"])
        XCTAssertEqual(answer2, "Elsewhere.md", "another vault, by name")
        let missing = await refusal("notes_read", ["path": "Nowhere"])
        XCTAssertNotNil(missing)
    }

    func testWritingANote() async throws {
        let answer3 = try await call("notes_write", ["path": "Ideas/New", "text": "# New\n"])
        XCTAssertEqual(answer3, "Created Ideas/New.md in “Main”.")
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("Ideas/New.md"), encoding: .utf8), "# New\n")
        XCTAssertEqual(host.written, ["New.md"], "the page is told")
        let again = await refusal("notes_write", ["path": "Ideas/New.md", "text": "x"])
        XCTAssertTrue(again?.contains("is there already") == true, "create never writes over a note")
        _ = try await call("notes_write", ["path": "Ideas/New.md", "text": "- more", "mode": "append"])
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("Ideas/New.md"), encoding: .utf8), "# New\n- more")
        _ = try await call("notes_write", ["path": "Ideas/New.md", "text": "replaced", "mode": "replace"])
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("Ideas/New.md"), encoding: .utf8), "replaced")
        XCTAssertTrue(host.notesWorkspace.index?.entries["Ideas/New.md"] != nil || host.written.count == 3)
    }

    func testNeverOutsideAVaultNorOverUnsavedEdits() async throws {
        for path in ["../escape.md", "/etc/hosts", "~/x.md", ".overterm/notes.json", "a/../../b.md"] {
            let refused = await refusal("notes_write", ["path": path, "text": "x"])
            XCTAssertNotNil(refused, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape.md").path))
        host.editedHere = ["Inbox.md"]
        let open = await refusal("notes_write", ["path": "Inbox.md", "text": "x", "mode": "append"])
        XCTAssertTrue(open?.contains("unsaved changes") == true, open ?? "")
        XCTAssertTrue(try String(contentsOf: vault.appendingPathComponent("Inbox.md"), encoding: .utf8).hasPrefix("# Inbox"))
    }

    func testTodaysNote() async throws {
        let first = try await call("notes_daily", ["text": "- [ ] ship notes"])
        let path = host.notesWorkspace.config.dailyNote(for: Date())
        XCTAssertEqual(first, "Added to today's note, \(path), in “Main”.")
        _ = try await call("notes_daily", ["text": "- [ ] tell Ali"])
        let text = try String(contentsOf: vault.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(text, "# \(NoteLinks.name(of: path))\n\n- [ ] ship notes\n- [ ] tell Ali\n")
    }

    /// Over JSON-RPC, as the bridge hands it on.
    func testTheServerRoutesNoteToolsHere() async throws {
        let answer = await BrowserMCP.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "notes_vaults", "arguments": [:]]], browser: { nil },
            notes: { self.host })
        let result = try XCTUnwrap(answer?["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        if Settings.shared.notesAgentControl {
            XCTAssertTrue(text.contains("Main"), text)
        } else {
            XCTAssertEqual(result["isError"] as? Bool, true)
        }
        XCTAssertEqual(
            BrowserMCP.offered.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("notes_") }.count,
            Settings.shared.notesAgentControl ? 7 : 0)
    }
}
