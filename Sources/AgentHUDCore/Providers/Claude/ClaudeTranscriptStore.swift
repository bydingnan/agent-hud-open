import Foundation

/// Scans `~/.claude/projects` for transcripts and reads only the bytes appended since the last pass. Indexing is
/// cooperative: each call reads newest files first for at most `timeBudget` seconds and reports how many are still
/// pending, so the UI shows data right away. Parse positions and summaries live in the usage ledger, and each
/// transcript's token events are one ledger contribution, so a restart only reads files that changed.
public actor ClaudeTranscriptStore {
    private struct Entry: Codable, Sendable {
        var mtime: Date
        var size: Int
        var offset: Int
        var accumulator: TranscriptAccumulator
    }

    /// The persisted form of an entry. A different version is read again from the transcript.
    private struct StoredEntry: Codable {
        static let version = 1
        let version: Int
        let offset: Int
        let accumulator: TranscriptAccumulator
    }

    /// Work done by the last `index` call, for diagnostics.
    public struct ScanStats: Hashable, Sendable {
        public var files = 0
        public var filesRead = 0
        public var bytesRead = 0
        public var pending = 0
        public var elapsed: TimeInterval = 0
    }

    public struct Result: Sendable {
        public let sessions: [TranscriptSession]
        /// Files still waiting to be (re)read; zero once the index is complete.
        public let pending: Int
    }

    /// Claude Code writes to `~/.claude/projects`; newer builds may use the XDG config directory instead.
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
    }

    public static let defaultTimeBudget: TimeInterval = 1.5
    static let source = "claude"

    let roots: [URL]
    private let ledger: UsageLedger
    private let logs: LogFiles
    private var entries: [String: Entry] = [:]
    /// Persisted entries not decoded yet; most transcripts are older than the window and never need it.
    private var stored: [String: UsageLedger.FileState] = [:]
    private var loadedGeneration: Int?
    private var sessionsByPath: [String: TranscriptSession] = [:]
    public private(set) var lastScan = ScanStats()

    /// - watchesChanges: after the first listing, polls look only at transcripts a directory watch reports changed.
    public init(roots: [URL] = ClaudeTranscriptStore.defaultRoots, ledger: UsageLedger = .inMemory(), watchesChanges: Bool = false) {
        self.roots = roots
        self.ledger = ledger
        logs = LogFiles(roots: roots, watchesChanges: watchesChanges) { $0.pathExtension == "jsonl" }
    }

    public init(root: URL) {
        self.init(roots: [root])
    }

    /// Sessions whose transcript file was modified at or after `cutoff`. Blocks until the index is complete.
    public func sessions(modifiedSince cutoff: Date) async -> [TranscriptSession] {
        await index(modifiedSince: cutoff, timeBudget: .infinity).sessions
    }

    /// Input plus output tokens of each transcript at or after `since`, keyed by path.
    public func tokens(since: Date) async -> [String: Int] {
        (try? await ledger.tokens(source: Self.source, since: since)) ?? [:]
    }

    /// Claude's 15-minute token totals from the period holding `since`.
    public func usage(since: Date) async -> [UsageBucket] {
        (try? await ledger.buckets(since: since, source: Self.source)) ?? []
    }

    /// One cooperative indexing step: newest changed files first, bounded by `timeBudget`.
    public func index(modifiedSince cutoff: Date, timeBudget: TimeInterval = ClaudeTranscriptStore.defaultTimeBudget) async -> Result {
        await loadIfNeeded()
        let started = Date()
        lastScan = ScanStats()
        defer { lastScan.elapsed = Date().timeIntervalSince(started) }

        let (seen, pending, scanFailures) = scan(modifiedSince: cutoff, now: started)
        var failures = scanFailures

        // Always make progress on the newest file, then keep going while the budget lasts.
        var remaining = 0
        var changed: [String: (entry: Entry, events: [UsageLedger.Event], reset: Bool)] = [:]
        for (index, candidate) in pending.enumerated() {
            if index > 0, Date().timeIntervalSince(started) >= timeBudget {
                remaining = pending.count - index
                break
            }
            if let update = load(url: candidate.url, mtime: candidate.mtime, size: candidate.size) {
                changed[candidate.url.path] = update
            } else {
                failures += 1
            }
        }
        // Files that still exist keep their contributions until the ledger's retention; deleted files leave now.
        let removed = failures == 0 ? Set(entries.keys).union(stored.keys).filter { logs.files[$0] == nil && logs.covers($0) } : []
        if !changed.isEmpty || !removed.isEmpty {
            let writes = changed.map { path, update in
                (path: path, reset: update.reset, events: update.events, state: Self.state(update.entry))
            }
            do {
                try await ledger.write { writer in
                    for write in writes {
                        if write.reset { try writer.remove(source: Self.source, contribution: write.path) }
                        try writer.upsert(source: Self.source, contribution: write.path, events: write.events)
                        try writer.setFile(source: Self.source, path: write.path, state: write.state)
                    }
                    for path in removed {
                        try writer.remove(source: Self.source, contribution: path)
                        try writer.removeFile(source: Self.source, path: path)
                    }
                }
                for (path, update) in changed {
                    entries[path] = update.entry
                    sessionsByPath[path] = update.entry.accumulator.build()
                }
                for path in removed {
                    entries.removeValue(forKey: path)
                    stored.removeValue(forKey: path)
                    sessionsByPath.removeValue(forKey: path)
                }
            } catch {
                // Positions stay where the ledger has them, so the next poll reads the same bytes again.
                failures += changed.count
            }
        }

        var result: [TranscriptSession] = []
        result.reserveCapacity(seen.count)
        for key in seen {
            if let cached = sessionsByPath[key] {
                result.append(cached)
            } else if let entry = entry(key), let built = entry.accumulator.build() {
                sessionsByPath[key] = built
                result.append(built)
            }
        }
        lastScan.pending = remaining + failures
        return Result(sessions: result, pending: lastScan.pending)
    }

    private struct Candidate {
        let url: URL
        let mtime: Date
        let size: Int
    }

    /// Transcripts modified since `cutoff`, and the changed ones newest first.
    private func scan(modifiedSince cutoff: Date, now: Date) -> (seen: Set<String>, pending: [Candidate], failures: Int) {
        let failures = logs.refresh(now: now)
        var seen: Set<String> = []
        var pending: [Candidate] = []
        for (path, file) in logs.files where file.modified >= cutoff {
            seen.insert(path)
            lastScan.files += 1
            if let entry = entry(path), entry.size == file.size, abs(entry.mtime.timeIntervalSince(file.modified)) < 0.001 { continue }
            pending.append(Candidate(url: URL(fileURLWithPath: path), mtime: file.modified, size: file.size))
        }
        return (seen, pending.sorted { $0.mtime > $1.mtime }, failures)
    }

    /// Reads persisted positions once, and again after a failed pass rolled the ledger back.
    private func loadIfNeeded() async {
        let generation = await ledger.generation
        guard loadedGeneration != generation else { return }
        stored = (try? await ledger.fileStates(source: Self.source)) ?? [:]
        entries = [:]
        sessionsByPath = [:]
        loadedGeneration = generation
    }

    private func entry(_ path: String) -> Entry? {
        if let entry = entries[path] { return entry }
        guard let file = stored.removeValue(forKey: path), let entry = Self.entry(file) else { return nil }
        entries[path] = entry
        return entry
    }

    private func load(url: URL, mtime: Date, size: Int) -> (entry: Entry, events: [UsageLedger.Event], reset: Bool)? {
        let now = Date()
        let existing = entry(url.path)
        if var entry = existing, size >= entry.offset, let (events, offset) = try? readEvents(url: url, from: entry.offset) {
            let added = entry.accumulator.ingest(events)
            entry.offset = offset
            entry.mtime = mtime
            entry.size = size
            entry.accumulator.compactIfFinished(now: now)
            return (entry, added, false)
        }
        guard let (events, offset) = try? readEvents(url: url, from: 0) else { return nil }
        var accumulator = TranscriptAccumulator(path: url.path, isSubagent: Self.isSubagent(url))
        let added = accumulator.ingest(events)
        accumulator.compactIfFinished(now: now)
        // A rewritten transcript replaces everything its earlier contents contributed.
        return (Entry(mtime: mtime, size: size, offset: offset, accumulator: accumulator), added, existing != nil)
    }

    /// Reads complete lines from `offset` in 4 MB chunks (transcripts can be hundreds of MB);
    /// returns the events and the offset just past the last newline consumed.
    private func readEvents(url: URL, from offset: Int) throws -> ([TranscriptEvent], Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        lastScan.filesRead += 1
        var events: [TranscriptEvent] = []
        var carry = Data()
        var consumed = 0
        let chunkSize = 4 << 20
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            lastScan.bytesRead += chunk.count
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry[carry.startIndex...lastNewline]
            events += FastTranscriptParser.parse(complete)
            consumed += complete.count
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        return (events, offset + consumed)
    }

    private static func state(_ entry: Entry) -> UsageLedger.FileState {
        let data = try? JSONEncoder().encode(StoredEntry(version: StoredEntry.version, offset: entry.offset, accumulator: entry.accumulator))
        return UsageLedger.FileState(signature: signature(mtime: entry.mtime, size: entry.size), state: data)
    }

    private static func entry(_ file: UsageLedger.FileState) -> Entry? {
        let parts = file.signature.split(separator: ":")
        guard parts.count == 2, let milliseconds = Int64(parts[0]), let size = Int(parts[1]), let data = file.state,
              let stored = try? JSONDecoder().decode(StoredEntry.self, from: data), stored.version == StoredEntry.version else { return nil }
        return Entry(mtime: Date(timeIntervalSince1970: Double(milliseconds) / 1000), size: size, offset: stored.offset, accumulator: stored.accumulator)
    }

    private static func signature(mtime: Date, size: Int) -> String {
        "\(Int64((mtime.timeIntervalSince1970 * 1000).rounded())):\(size)"
    }

    static func isSubagent(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("agent-") || url.pathComponents.contains("subagents")
    }
}
