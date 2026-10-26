import Foundation

/// Where a file in a vault stands with iCloud Drive.
struct CloudState: Equatable, Sendable {
    enum Download: Equatable, Sendable {
        /// On this Mac (or not in iCloud at all).
        case local
        /// Only in iCloud: reading it downloads it first (about a second).
        case cloud
        case downloading
    }

    var download: Download = .local
    /// Not yet in iCloud: written here, still going up.
    var isUploading = false
    /// Another device changed it at the same time; iCloud kept both.
    var hasConflicts = false

    static let local = CloudState()
}

/// A version iCloud kept when two devices changed a file apart.
struct ConflictVersion: Equatable, Sendable {
    /// Where its contents can be read.
    var url: URL
    var modified: Date?
    /// The device it came from ("Ali's iPhone").
    var device: String?
}

/// A vault's files as iCloud Drive keeps them: a protocol, so the notes
/// can be tested without iCloud (`SimulatedCloudFiles`). What it does
/// follows the spike (docs/design/notes/plan.md, 4):
///
/// - Reading a file that is only in iCloud downloads it and blocks the
///   reader about a second, whatever its size, coordinated or not — never
///   on the main thread. Many at once go as one request
///   (`startDownloading`): 40 files in two seconds, not forty.
/// - Writing is coordinated and atomic. Written over with `.forReplacing`,
///   a file in iCloud is not downloaded first.
/// - Evicting and downloading change a file's flags, not its size or
///   modification date: those two say whether its text changed.
///
/// Called off the main thread; every method may block.
protocol CloudFiles: Sendable {
    func state(of url: URL) -> CloudState
    /// Asks iCloud for each of `urls` that is only in the cloud, at once.
    func startDownloading(_ urls: [URL])
    /// The file's bytes, coordinated with iCloud's own reads and writes.
    func read(_ url: URL) throws -> Data
    /// The file written whole, coordinated, atomically; folders made.
    func write(_ data: Data, to url: URL) throws
    /// Renamed or moved, coordinated: iCloud keeps it as the same file.
    func move(_ url: URL, to destination: URL) throws
    /// To the Trash (iCloud Drive's Recently Deleted for a file there).
    func trash(_ url: URL) throws
    func conflicts(of url: URL) -> [ConflictVersion]
    /// Settles a conflict: `keeping` nil keeps the file as it is, else that
    /// version's contents replace it. The other versions go.
    func resolveConflicts(of url: URL, keeping: ConflictVersion?) throws
}

extension CloudFiles {
    /// The text of a note: UTF-8, as notes are.
    func readText(_ url: URL) throws -> String {
        let data = try read(url)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    func writeText(_ text: String, to url: URL) throws { try write(Data(text.utf8), to: url) }
}

/// macOS 13 keeps a file that is only in iCloud as a hidden placeholder
/// beside where it would be: `Note.md` as `.Note.md.icloud`. Later macOS
/// keeps the file itself, dataless; this maps the old form.
enum CloudPlaceholder {
    /// `.Note.md.icloud` → `Note.md`; nil for any other name.
    static func file(forPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let inner = String(name.dropFirst().dropLast(".icloud".count))
        return inner.isEmpty ? nil : inner
    }

    /// Names a listing of a vault folder leaves out: hidden ones (the
    /// placeholders are mapped first), and the temporary files an atomic
    /// write leaves beside its file for a moment (`Note.md.sb-…`).
    static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(".") || name.range(of: #"\.sb-[0-9a-f]+-[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }
}

/// The real thing: iCloud Drive (or any folder) through FileManager,
/// NSFileCoordinator and NSFileVersion — no entitlement needed for a
/// folder in iCloud Drive.
struct ICloudDriveFiles: CloudFiles {
    func state(of url: URL) -> CloudState {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadedKey, .ubiquitousItemHasUnresolvedConflictsKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return .local }
        var state = CloudState()
        if values.ubiquitousItemIsDownloading == true {
            state.download = .downloading
        } else if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            state.download = .cloud
        }
        state.isUploading = values.ubiquitousItemIsUploaded == false
        state.hasConflicts = values.ubiquitousItemHasUnresolvedConflicts == true
        return state
    }

    func startDownloading(_ urls: [URL]) {
        for url in urls where state(of: url).download == .cloud {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    func read(_ url: URL) throws -> Data {
        var coordination: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordination { throw coordination }
        return try result.get()
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do { try data.write(to: url, options: .atomic) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    func move(_ url: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &coordination
        ) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    func trash(_ url: URL) throws {
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordination) { url in
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    func conflicts(of url: URL) -> [ConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
            ConflictVersion(url: $0.url, modified: $0.modificationDate, device: $0.localizedNameOfSavingComputer)
        }
    }

    func resolveConflicts(of url: URL, keeping: ConflictVersion?) throws {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        if let keeping, let version = versions.first(where: { $0.url == keeping.url }) {
            var coordination: NSError?
            var failure: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
                do { try version.replaceItem(at: url, options: []) } catch { failure = error }
            }
            if let error = coordination ?? failure { throw error }
        }
        for version in versions { version.isResolved = true }
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}

/// iCloud played by a plain folder, for the tests and the E2E scenarios:
/// a file can be put "in the cloud" (reading it then waits `latency` and
/// brings it down), "uploading", or given a conflicting version.
final class SimulatedCloudFiles: CloudFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var inCloud = Set<String>()
    private var downloading = Set<String>()
    private var uploading = Set<String>()
    private var versions: [String: [ConflictVersion]] = [:]
    private(set) var reads: [String] = []
    let latency: TimeInterval
    private let local = ICloudDriveFiles()

    init(latency: TimeInterval = 0) { self.latency = latency }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func putInCloud(_ url: URL) { locked { _ = inCloud.insert(url.standardizedFileURL.path) } }
    func setUploading(_ url: URL, _ on: Bool) {
        let path = url.standardizedFileURL.path
        locked {
            if on { uploading.insert(path) } else { uploading.remove(path) }
        }
    }

    /// Another device's version of `url`, with `text` in it.
    func addConflict(_ url: URL, text: String, device: String = "iPhone") throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-\(UUID().uuidString).md")
        try Data(text.utf8).write(to: copy)
        locked { versions[url.standardizedFileURL.path, default: []].append(ConflictVersion(url: copy, modified: Date(), device: device)) }
    }

    func state(of url: URL) -> CloudState {
        let path = url.standardizedFileURL.path
        return locked {
            var state = CloudState()
            if downloading.contains(path) { state.download = .downloading } else if inCloud.contains(path) { state.download = .cloud }
            state.isUploading = uploading.contains(path)
            state.hasConflicts = !(versions[path] ?? []).isEmpty
            return state
        }
    }

    func startDownloading(_ urls: [URL]) {
        let paths = urls.map(\.standardizedFileURL.path)
        let started = locked { paths.filter { inCloud.contains($0) && downloading.insert($0).inserted } }
        guard !started.isEmpty else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + latency) { [self] in
            locked {
                for path in started {
                    downloading.remove(path)
                    inCloud.remove(path)
                }
            }
        }
    }

    func read(_ url: URL) throws -> Data {
        let path = url.standardizedFileURL.path
        if locked({ inCloud.contains(path) }) {
            Thread.sleep(forTimeInterval: latency)
            locked {
                inCloud.remove(path)
                downloading.remove(path)
            }
        }
        locked { reads.append(path) }
        return try local.read(url)
    }

    func write(_ data: Data, to url: URL) throws {
        try local.write(data, to: url)
        locked { _ = inCloud.remove(url.standardizedFileURL.path) }
    }

    func move(_ url: URL, to destination: URL) throws { try local.move(url, to: destination) }
    func trash(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    func conflicts(of url: URL) -> [ConflictVersion] { locked { versions[url.standardizedFileURL.path] ?? [] } }

    func resolveConflicts(of url: URL, keeping: ConflictVersion?) throws {
        if let keeping { try local.write(try Data(contentsOf: keeping.url), to: url) }
        locked { _ = versions.removeValue(forKey: url.standardizedFileURL.path) }
    }
}
