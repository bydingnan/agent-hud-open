import Foundation

/// The log files under a set of roots with their modification times and sizes. With a directory watch, a poll looks
/// only at the files reported changed; without one, or every five minutes and whenever events were dropped, it lists
/// every file again.
final class LogFiles {
    struct File: Equatable {
        let modified: Date
        let size: Int
    }

    static let fullScanInterval: TimeInterval = 300

    private let roots: [URL]
    private let accepts: (URL) -> Bool
    private let monitor: FileChangeMonitor?
    private(set) var files: [String: File] = [:]
    private var scannedAt: Date?
    /// Roots that exist, under the names a listing and a change event can use.
    private var existingRoots: [String] = []

    init(roots: [URL], watchesChanges: Bool, accepts: @escaping (URL) -> Bool) {
        self.roots = roots
        self.accepts = accepts
        monitor = watchesChanges ? FileChangeMonitor(directories: roots) : nil
    }

    /// Brings `files` up to date and returns how many entries of a full listing could not be read; an unreadable tree
    /// is not an authoritative snapshot of the user's history.
    func refresh(now: Date) -> Int {
        monitor?.update()
        existingRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }
        let changed = monitor?.consumePaths()
        if let changed, let scannedAt, now.timeIntervalSince(scannedAt) < Self.fullScanInterval {
            for path in changed.compactMap(canonical) {
                let url = URL(fileURLWithPath: path)
                guard accepts(url) else { continue }
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                   values.isRegularFile == true, let modified = values.contentModificationDate, let size = values.fileSize {
                    files[path] = File(modified: modified, size: size)
                } else if !FileManager.default.fileExists(atPath: path) {
                    files.removeValue(forKey: path)
                }
            }
            return 0
        }
        return scan(now: now)
    }

    private func scan(now: Date) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var listed: [String: File] = [:]
        var failures = 0
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in
                failures += 1
                return true
            }) else {
                failures += 1
                continue
            }
            for case let url as URL in enumerator {
                guard accepts(url) else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), let modified = values.contentModificationDate,
                      let size = values.fileSize, values.isRegularFile != nil else { failures += 1; continue }
                if values.isRegularFile == true { listed[url.path] = File(modified: modified, size: size) }
            }
        }
        files = listed
        scannedAt = now
        return failures
    }

    /// Change events can name a root by its resolved path; files are keyed as the listing names them.
    private func canonical(_ path: String) -> String? {
        for root in roots {
            if path.hasPrefix(root.path + "/") { return path }
            let resolved = root.resolvingSymlinksInPath().path
            if resolved != root.path, path.hasPrefix(resolved + "/") { return root.path + path.dropFirst(resolved.count) }
        }
        return nil
    }

    /// Whether `path` lies under a root that existed at the last refresh, so its absence from `files` means the file was deleted.
    /// A root that disappeared entirely (an unmounted or renamed directory) is not a deletion of its history.
    func covers(_ path: String) -> Bool {
        existingRoots.contains { path.hasPrefix($0 + "/") }
    }
}
