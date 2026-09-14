import AgentHUDSupport
import Foundation

/// Incremental metadata reader for plaintext and concatenated Zstandard-frame Harness logs over the usage ledger.
/// Each log is one ledger contribution; when a session's log exists in several places, only its newest copy counts.
public actor DeepSeekTranscriptStore {
    private struct Entry: Codable, Sendable {
        var modifiedAt: Date
        var size: Int
        var offset: Int
        var committedSize: Int
        var transcript: DeepSeekTranscript
    }

    /// The persisted form of an entry. A different version is read again from the log.
    private struct StoredEntry: Codable {
        static let version = 1
        let version: Int
        let offset: Int
        let committedSize: Int
        let transcript: DeepSeekTranscript
    }

    public struct Session: Sendable {
        public let transcript: DeepSeekTranscript
        public let modifiedAt: Date
        public let path: String
    }

    public struct Result: Sendable {
        public let sessions: [Session]
        public let indexing: IndexProgress?
        public let notice: String?
    }

    static let source = "deepseek"

    let root: URL
    private let ledger: UsageLedger
    private var entries: [String: Entry] = [:]
    private var stored: [String: UsageLedger.FileState] = [:]
    private var groups: [String: String] = [:]
    private var modified: [String: Date] = [:]
    private var loadedGeneration: Int?

    public init(root: URL, ledger: UsageLedger = .inMemory()) {
        self.root = root
        self.ledger = ledger
    }

    /// DeepSeek's 15-minute token totals from the period holding `since`.
    public func usage(since: Date) async -> [UsageBucket] {
        (try? await ledger.buckets(since: since, source: Self.source)) ?? []
    }

    /// Estimated cost periods of the Harness account, and each log's estimate keyed by path.
    public func costs(since: Date) async -> (buckets: [CostBucket], logs: [String: [String: Decimal]]) {
        let buckets = (try? await ledger.costBuckets(since: since))?["DeepSeek"] ?? []
        return (buckets, (try? await ledger.contributionCosts(source: Self.source)) ?? [:])
    }

    public func index(since cutoff: Date, timeBudget: TimeInterval = 1.5) async -> Result {
        await loadIfNeeded()
        let deadline = Date().addingTimeInterval(timeBudget)
        var (candidates, present, notice) = scan(since: cutoff)
        var pending = 0
        var changed: [String: (entry: Entry, events: [UsageLedger.Event], reset: Bool)] = [:]
        for candidate in candidates {
            let old = entry(candidate.url.path)
            if let old, old.size == candidate.size, LedgerCopies.same(old.modifiedAt, candidate.modified), old.offset == old.committedSize { continue }
            if Date() >= deadline { pending += 1; continue }
            do {
                // Compressed streams replay on change; the summary resumes at its decoded byte offset.
                let data = try DeepSeekLogReader.read(candidate.url)
                var entry = old ?? Entry(modifiedAt: candidate.modified, size: candidate.size, offset: 0, committedSize: 0, transcript: DeepSeekTranscript())
                var reset = false
                if candidate.size < entry.size || data.count < entry.offset || (old?.size == candidate.size && !LedgerCopies.same(old!.modifiedAt, candidate.modified)) {
                    entry.offset = 0; entry.transcript = DeepSeekTranscript()
                    reset = old != nil
                }
                entry.committedSize = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
                while entry.offset < entry.committedSize, Date() < deadline,
                      let newline = data[entry.offset...].firstIndex(of: 0x0A) {
                    let line = Data(data[entry.offset..<newline])
                    if !line.isEmpty { try entry.transcript.ingest(line) }
                    entry.offset = newline + 1
                }
                entry.modifiedAt = candidate.modified; entry.size = candidate.size
                let events = entry.transcript.drainUsage()
                changed[candidate.url.path] = (entry, events, reset)
                if entry.offset < entry.committedSize { pending += 1 }
            } catch {
                notice = L10n.text("Harness 会话读取失败：", "Harness session read failed: ") + error.localizedDescription
            }
        }
        let known = Set(entries.keys).union(stored.keys)
        let roots = FileManager.default.fileExists(atPath: root.path) ? [root.path, root.resolvingSymlinksInPath().path] : []
        let removed = known.subtracting(present).filter { path in roots.contains { path.hasPrefix($0 + "/") } }
        if !changed.isEmpty || !removed.isEmpty {
            var nextGroups = groups, nextModified = modified
            for (path, update) in changed {
                nextGroups[path] = update.entry.transcript.id ?? ""
                nextModified[path] = update.entry.modifiedAt
            }
            for path in removed { nextGroups.removeValue(forKey: path); nextModified.removeValue(forKey: path) }
            let counted = LedgerCopies.counted(touched: Set(changed.keys).union(removed), previous: groups, members: nextGroups, modified: nextModified)
            let writes = changed.map { path, update in
                (path: path, reset: update.reset, events: update.events, state: Self.state(update.entry))
            }
            do {
                try await ledger.write { writer in
                    for write in writes {
                        if write.reset { try writer.remove(source: Self.source, contribution: write.path) }
                        try writer.upsert(source: Self.source, contribution: write.path, counted: counted[write.path] ?? false, events: write.events)
                        try writer.setFile(source: Self.source, path: write.path, state: write.state)
                    }
                    for path in removed {
                        try writer.remove(source: Self.source, contribution: path)
                        try writer.removeFile(source: Self.source, path: path)
                    }
                    for (path, value) in counted where writes.allSatisfy({ $0.path != path }) {
                        try writer.setCounted(source: Self.source, contribution: path, counted: value)
                    }
                }
                for (path, update) in changed { entries[path] = update.entry }
                for path in removed { entries.removeValue(forKey: path); stored.removeValue(forKey: path) }
                groups = nextGroups
                modified = nextModified
            } catch {
                pending += changed.count
            }
        }
        candidates.sort { $0.modified > $1.modified }
        // Session ids own usage even if a log has been copied between project directories.
        var sessions: [String: Session] = [:]
        for candidate in candidates {
            guard let entry = entry(candidate.url.path), let id = entry.transcript.id, sessions[id] == nil else { continue }
            sessions[id] = Session(transcript: entry.transcript, modifiedAt: entry.modifiedAt, path: candidate.url.path)
        }
        return Result(sessions: sessions.values.sorted { $0.transcript.id! < $1.transcript.id! },
                      indexing: pending > 0 ? IndexProgress(done: candidates.count - pending, total: candidates.count) : nil, notice: notice)
    }

    private func scan(since cutoff: Date) -> (candidates: [(url: URL, modified: Date, size: Int)], present: Set<String>, notice: String?) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var candidates: [(url: URL, modified: Date, size: Int)] = []
        var present: Set<String> = []
        var notice: String?
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], [], nil) }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in
            notice = L10n.text("无法读取部分 Harness 会话目录", "Some Harness session directories could not be read")
            return true
        })
        for case let url as URL in files ?? FileManager.DirectoryEnumerator() {
            guard ["session.jsonl", "session.jsonl.zstd"].contains(url.lastPathComponent) else { continue }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, let modified = values.contentModificationDate, let size = values.fileSize else { continue }
                present.insert(url.path)
                if modified >= cutoff { candidates.append((url, modified, size)) }
            } catch { notice = L10n.text("无法读取部分 Harness 会话", "Some Harness sessions could not be read") }
        }
        return (candidates.sorted { $0.modified > $1.modified }, present, notice)
    }

    private func loadIfNeeded() async {
        let generation = await ledger.generation
        guard loadedGeneration != generation else { return }
        stored = (try? await ledger.fileStates(source: Self.source)) ?? [:]
        entries = [:]
        groups = stored.mapValues { $0.group ?? "" }
        modified = stored.compactMapValues { LedgerCopies.signature($0.signature)?.modified }
        loadedGeneration = generation
    }

    private func entry(_ path: String) -> Entry? {
        if let entry = entries[path] { return entry }
        guard let file = stored.removeValue(forKey: path), let parts = LedgerCopies.signature(file.signature), let data = file.state,
              let decoded = try? JSONDecoder().decode(StoredEntry.self, from: data), decoded.version == StoredEntry.version else { return nil }
        let entry = Entry(modifiedAt: parts.modified, size: parts.size, offset: decoded.offset, committedSize: decoded.committedSize,
                          transcript: decoded.transcript)
        entries[path] = entry
        return entry
    }

    private static func state(_ entry: Entry) -> UsageLedger.FileState {
        let data = try? JSONEncoder().encode(StoredEntry(version: StoredEntry.version, offset: entry.offset,
                                                         committedSize: entry.committedSize, transcript: entry.transcript))
        return UsageLedger.FileState(signature: LedgerCopies.signature(modified: entry.modifiedAt, size: entry.size), state: data,
                                     group: entry.transcript.id ?? "")
    }
}

/// Logs that can exist in several places for one session: only the newest copy of each session counts.
enum LedgerCopies {
    /// Counting flags for every copy of the sessions that `touched` files belong to, before or after this pass.
    /// A file without a session id never counts.
    static func counted(touched: Set<String>, previous: [String: String], members: [String: String],
                        modified: [String: Date]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        let affected = Set(touched.compactMap { members[$0] } + touched.compactMap { previous[$0] }).subtracting([""])
        for group in affected {
            let paths = members.filter { $0.value == group }.map(\.key)
            let newest = paths.max { (modified[$0] ?? .distantPast, $1) < (modified[$1] ?? .distantPast, $0) }
            for path in paths { result[path] = path == newest }
        }
        for path in touched where members[path]?.isEmpty == true { result[path] = false }
        return result
    }

    /// Modification times persist in milliseconds, so a restart compares them to the millisecond.
    static func signature(modified: Date, size: Int) -> String { "\(RecordCoding.milliseconds(modified)):\(size)" }

    static func signature(_ text: String) -> (modified: Date, size: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let milliseconds = Int64(parts[0]), let size = Int(parts[1]) else { return nil }
        return (RecordCoding.date(milliseconds), size)
    }

    static func same(_ stored: Date, _ current: Date) -> Bool { abs(stored.timeIntervalSince(current)) < 0.001 }
}
