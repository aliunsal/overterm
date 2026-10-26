import Foundation

/// A folder of notes. Which folders are vaults is this Mac's business
/// (`NoteVaults`); how one is laid out travels with it (`VaultConfig`).
struct Vault: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    init(id: UUID = UUID(), url: URL, name: String? = nil) {
        self.id = id
        self.path = url.standardizedFileURL.path
        self.name = name ?? url.lastPathComponent
    }

    /// In iCloud Drive (synced), or a folder only this Mac has.
    var isInICloudDrive: Bool { path.contains("/Library/Mobile Documents/") }
}

/// This Mac's vaults and the one last open: `vaults.json` in the support
/// directory, beside `snippets.json` — not a setting, since the settings
/// hold no lists of folders, and not in the vault, since another Mac has
/// its own folders.
@MainActor
final class NoteVaults: ObservableObject {
    private struct File: Codable {
        var vaults: [Vault]
        var lastOpened: UUID?
    }

    @Published private(set) var vaults: [Vault] = []
    @Published private(set) var lastOpened: UUID?
    let url: URL

    static var defaultURL: URL { AppEnvironment.supportDirectory.appendingPathComponent("vaults.json") }

    init(url: URL = defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            vaults = file.vaults
            lastOpened = file.lastOpened
        } else if FileManager.default.fileExists(atPath: url.path) {
            UnreadableFile.setAside(url)
        }
    }

    /// The vault to open: the last one, else the first.
    var current: Vault? { vaults.first { $0.id == lastOpened } ?? vaults.first }

    /// `folder` as a vault (made if it isn't there); the one it already is,
    /// if it is.
    @discardableResult
    func add(_ folder: URL, name: String? = nil) throws -> Vault {
        let path = folder.standardizedFileURL.path
        if let existing = vaults.first(where: { $0.path == path }) { return existing }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vault = Vault(url: folder, name: name)
        vaults.append(vault)
        save()
        return vault
    }

    /// Out of the list; its folder and notes stay where they are.
    func remove(_ vault: Vault) {
        vaults.removeAll { $0.id == vault.id }
        if lastOpened == vault.id { lastOpened = nil }
        save()
    }

    func rename(_ vault: Vault, to name: String) {
        guard let i = vaults.firstIndex(where: { $0.id == vault.id }), !name.isEmpty else { return }
        vaults[i].name = name
        save()
    }

    func opened(_ vault: Vault) {
        guard lastOpened != vault.id else { return }
        lastOpened = vault.id
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(vaults: vaults, lastOpened: lastOpened)).write(to: url, options: .atomic)
        } catch {
            GhosttyRuntime.logger.error("vaults save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// How a vault is laid out, kept in it — `.overterm/notes.json` — so every
/// Mac it syncs to agrees. Every key is optional; what is missing is the
/// default, and a file nobody wrote is all defaults.
struct VaultConfig: Codable, Equatable {
    /// Where daily notes go, and what they are called (a date format:
    /// `yyyy-MM-dd`).
    var dailyFolder = "Daily"
    var dailyFormat = "yyyy-MM-dd"
    /// Where a pasted or dropped image goes.
    var attachmentsFolder = "attachments"
    var templatesFolder = "Templates"
    /// Where a new note goes; empty is the vault's root.
    var newNotesFolder = ""

    static let path = ".overterm/notes.json"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VaultConfig()
        dailyFolder = try c.decodeIfPresent(String.self, forKey: .dailyFolder) ?? d.dailyFolder
        dailyFormat = try c.decodeIfPresent(String.self, forKey: .dailyFormat) ?? d.dailyFormat
        attachmentsFolder = try c.decodeIfPresent(String.self, forKey: .attachmentsFolder) ?? d.attachmentsFolder
        templatesFolder = try c.decodeIfPresent(String.self, forKey: .templatesFolder) ?? d.templatesFolder
        newNotesFolder = try c.decodeIfPresent(String.self, forKey: .newNotesFolder) ?? d.newNotesFolder
    }

    /// Read from the vault (through iCloud: it may be in the cloud). A file
    /// that can't be read leaves the defaults and is left as it is — it is
    /// the user's, on every device.
    static func load(from vault: URL, files: CloudFiles) -> VaultConfig {
        let url = vault.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path), let data = try? files.read(url),
            let config = try? JSONDecoder().decode(VaultConfig.self, from: data)
        else { return VaultConfig() }
        return config
    }

    func save(to vault: URL, files: CloudFiles) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.write(try encoder.encode(self), to: vault.appendingPathComponent(Self.path))
    }

    /// The daily note's path in the vault for `date`.
    func dailyNote(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dailyFormat.isEmpty ? "yyyy-MM-dd" : dailyFormat
        return NoteLinks.join(Self.folder(dailyFolder), formatter.string(from: date) + ".md")
    }

    /// A folder setting as a vault path: no leading or trailing slash.
    static func folder(_ setting: String) -> String {
        setting.split(separator: "/").joined(separator: "/")
    }
}
