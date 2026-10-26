import XCTest

@testable import Overterm

/// The vault's files, on temporary folders: never iCloud itself.
@MainActor
final class VaultFilesTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testPlaceholdersAndTheNamesAListingLeavesOut() {
        XCTAssertEqual(CloudPlaceholder.file(forPlaceholder: ".Not A.md.icloud"), "Not A.md")
        XCTAssertNil(CloudPlaceholder.file(forPlaceholder: "Not A.md"))
        XCTAssertNil(CloudPlaceholder.file(forPlaceholder: "..icloud"))
        XCTAssertTrue(CloudPlaceholder.isHidden(".overterm"))
        XCTAssertTrue(CloudPlaceholder.isHidden("Not D.md.sb-0542b826-qcqGyn"), "an atomic write's temporary file (the spike's)")
        XCTAssertFalse(CloudPlaceholder.isHidden("Not D.md"))
    }

    func testAFolderOutsideICloudIsLocal() throws {
        let note = dir.appendingPathComponent("a/Note.md")
        let files = ICloudDriveFiles()
        try files.writeText("# Hi", to: note)
        XCTAssertEqual(files.state(of: note), .local)
        XCTAssertEqual(try files.readText(note), "# Hi")
        let moved = dir.appendingPathComponent("b/Renamed.md")
        try files.move(note, to: moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertEqual(try files.readText(moved), "# Hi")
        XCTAssertTrue(files.conflicts(of: moved).isEmpty)
    }

    func testTheSimulatedCloudDownloadsOnReadAndHoldsConflicts() throws {
        let files = SimulatedCloudFiles(latency: 0.05)
        let note = dir.appendingPathComponent("Note.md")
        try files.writeText("mine", to: note)
        files.putInCloud(note)
        XCTAssertEqual(files.state(of: note).download, .cloud)
        let start = Date()
        XCTAssertEqual(try files.readText(note), "mine")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05, "reading waits for the download")
        XCTAssertEqual(files.state(of: note).download, .local)

        try files.addConflict(note, text: "theirs")
        XCTAssertTrue(files.state(of: note).hasConflicts)
        let theirs = try XCTUnwrap(files.conflicts(of: note).first)
        try files.resolveConflicts(of: note, keeping: theirs)
        XCTAssertEqual(try files.readText(note), "theirs")
        XCTAssertFalse(files.state(of: note).hasConflicts)
    }

    func testStartDownloadingBringsThemDownTogether() throws {
        let files = SimulatedCloudFiles(latency: 0.05)
        let notes = (1...5).map { dir.appendingPathComponent("T\($0).md") }
        for note in notes {
            try files.writeText("x", to: note)
            files.putInCloud(note)
        }
        files.startDownloading(notes)
        XCTAssertEqual(files.state(of: notes[0]).download, .downloading)
        let done = expectation(description: "downloaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(notes.allSatisfy { files.state(of: $0).download == .local })
    }

    func testVaultsAreAddedOnceRememberTheLastAndSurviveARestart() throws {
        let file = dir.appendingPathComponent("vaults.json")
        let vaults = NoteVaults(url: file)
        XCTAssertNil(vaults.current)
        let work = try vaults.add(dir.appendingPathComponent("Work"))
        let home = try vaults.add(dir.appendingPathComponent("Home"), name: "Personal")
        XCTAssertEqual(try vaults.add(dir.appendingPathComponent("Work/")).id, work.id, "the same folder twice is one vault")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path), "the folder is made")
        XCTAssertEqual(vaults.current?.id, work.id, "nothing opened yet: the first")
        vaults.opened(home)

        let again = NoteVaults(url: file)
        XCTAssertEqual(again.vaults.map(\.name), ["Work", "Personal"])
        XCTAssertEqual(again.current?.id, home.id)
        again.remove(home)
        XCTAssertEqual(again.current?.id, work.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path), "removing a vault leaves its notes")
    }

    func testAnUnreadableVaultListIsSetAside() throws {
        let file = dir.appendingPathComponent("vaults.json")
        try Data("{ not json".utf8).write(to: file)
        XCTAssertTrue(NoteVaults(url: file).vaults.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }.count, 1)
    }

    func testVaultConfigDefaultsWhatIsMissingAndRoundTrips() throws {
        let files = ICloudDriveFiles()
        XCTAssertEqual(VaultConfig.load(from: dir, files: files), VaultConfig(), "no file: the defaults")
        let config = dir.appendingPathComponent(VaultConfig.path)
        try files.writeText(#"{ "dailyFolder": "Günlük/", "dailyFormat": "dd.MM.yyyy" }"#, to: config)
        var loaded = VaultConfig.load(from: dir, files: files)
        XCTAssertEqual(loaded.dailyFolder, "Günlük/")
        XCTAssertEqual(loaded.attachmentsFolder, "attachments", "missing: the default")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertEqual(loaded.dailyNote(for: date, calendar: calendar), "Günlük/26.10.2026.md")

        loaded.newNotesFolder = "Inbox"
        try loaded.save(to: dir, files: files)
        XCTAssertEqual(VaultConfig.load(from: dir, files: files), loaded)

        try files.writeText("not json", to: config)
        XCTAssertEqual(VaultConfig.load(from: dir, files: files), VaultConfig(), "unreadable: the defaults")
        XCTAssertEqual(try files.readText(config), "not json", "and the file left as it is")
    }
}
