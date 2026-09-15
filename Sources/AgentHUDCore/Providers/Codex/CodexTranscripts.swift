import AgentHUDSupport
import Foundation

/// Incremental summary of Codex rollout JSONL, shared by Desktop and CLI.
/// It retains counters and lifecycle events, never conversation bodies or tool output.
public struct CodexTranscript: Codable, Sendable {
    public struct Usage: Codable, Sendable {
        public let timestamp: Date
        public let model: String
        public let input: Int
        public let output: Int
        public let cachedInput: Int

        public var event: UsageEvent {
            .init(timestamp: timestamp, agentId: "codex-model:\(model)", tokensIn: input, tokensOut: output, cacheReadTokens: cachedInput)
        }
    }

    public private(set) var id: String?
    public private(set) var cwd: String?
    public private(set) var client = "Codex"
    public private(set) var isSubagent = false
    public private(set) var isInternal = false
    public private(set) var startedAt: Date?
    public private(set) var lastActivityAt: Date?
    public private(set) var task: String?
    public private(set) var model = "Unknown"
    /// Usage read since the store last recorded it in the ledger; the totals below cover the whole rollout.
    public private(set) var usage: [Usage] = []
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var cachedInputTokens = 0
    /// Models that reported usage in this rollout.
    public private(set) var models: Set<String> = []
    /// Usage entries already recorded, so each keeps its position as its ledger key.
    private var recordedUsage = 0
    private struct Turn: Codable, Sendable {
        let id: String?
        let startedAt: Date?
        var state: SessionTurn.State
        var observedAt: Date
    }
    private var turns: [Turn]?
    public private(set) var completions: [SessionCompletion]?
    private var totalInput = 0
    private var totalCached = 0
    private var totalOutput = 0
    private var hasTotals = false

    public init() {}

    public mutating func ingest(_ line: Data) {
        // Rollouts can contain multi-MB tool outputs. Inspect the envelope before decoding.
        guard Self.envelopes.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any],
              let timestamp = (object["timestamp"] as? String).flatMap(ISO8601Fast.parse) else { return }
        if type == "session_meta" {
            id = payload["id"] as? String
            cwd = payload["cwd"] as? String
            startedAt = (payload["timestamp"] as? String).flatMap(ISO8601Fast.parse) ?? timestamp
            let source = payload["source"] as? String
            let origin = payload["originator"] as? String
            isSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
            if let subagent = (payload["source"] as? [String: Any])?["subagent"] as? [String: Any] {
                isInternal = subagent["other"] as? String == "guardian"
            }
            // CLI launched from Desktop can inherit its originator; the rollout's source is authoritative.
            if source == "cli" { client = "CLI" }
            else if source == "exec" { client = "CLI · exec" }
            else if origin == "Codex Desktop" { client = "Desktop" }
            else if source == "vscode" { client = "IDE" }
            return
        }
        if type == "turn_context" {
            if let value = payload["model"] as? String { model = value }
            return
        }
        guard type == "event_msg", let kind = payload["type"] as? String else { return }
        // Forks copy earlier history. Read its cumulative baseline but do not count it again.
        let inherited = timestamp < (startedAt ?? .distantPast)
        if kind == "token_count" {
            guard let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any],
                  let input = totals["input_tokens"] as? Int,
                  let output = totals["output_tokens"] as? Int else { return }
            let cached = totals["cached_input_tokens"] as? Int ?? 0
            let last = info["last_token_usage"] as? [String: Any]
            let reset = input < totalInput || output < totalOutput || cached < totalCached
            let inputDelta = hasTotals && !reset ? input - totalInput : (last?["input_tokens"] as? Int ?? input)
            let cachedDelta = hasTotals && !reset ? cached - totalCached : (last?["cached_input_tokens"] as? Int ?? cached)
            let outputDelta = hasTotals && !reset ? output - totalOutput : (last?["output_tokens"] as? Int ?? output)
            totalInput = input; totalCached = cached; totalOutput = output; hasTotals = true
            guard !inherited, inputDelta > 0 || outputDelta > 0 else { return }
            // Cached input is already included in input_tokens; reasoning is already in output_tokens.
            let sample = Usage(timestamp: timestamp, model: model, input: max(0, inputDelta - cachedDelta), output: max(0, outputDelta),
                               cachedInput: max(0, cachedDelta))
            usage.append(sample)
            inputTokens += sample.input
            outputTokens += sample.output
            cachedInputTokens += sample.cachedInput
            models.insert(model)
            lastActivityAt = timestamp
        } else if !inherited {
            switch kind {
            case "task_started":
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
                let turnID = payload["turn_id"] as? String
                if !(turns ?? []).contains(where: { $0.id == turnID && (turnID != nil || ($0.state == .running && $0.startedAt == timestamp)) }),
                   timestamp >= (turns?.last?.startedAt ?? .distantPast) {
                    turns = Array(((turns ?? []) + [Turn(id: turnID, startedAt: timestamp, state: .running, observedAt: timestamp)]).suffix(32))
                }
            case "task_complete":
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
                let finished = finishTurn(payload["turn_id"] as? String, state: .completed, at: timestamp)
                if let id, !isSubagent, !isInternal {
                    let completion = SessionCompletion(sessionID: id, vendor: "Codex",
                        turnID: payload["turn_id"] as? String ?? finished?.id ?? String(RecordCoding.milliseconds(timestamp)),
                        task: task ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
                        model: model, startedAt: finished?.startedAt, completedAt: timestamp)
                    if completions?.contains(where: { $0.id == completion.id }) != true {
                        completions = (completions ?? []) + [completion]
                    }
                }
            case "turn_aborted":
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
                _ = finishTurn(payload["turn_id"] as? String, state: .ended, at: timestamp)
            case "user_message":
                if task == nil, let text = payload["message"] as? String {
                    task = SessionTitle.from(text)
                }
            default: break
            }
        }
        // A source event can refresh an explicitly started turn, but never start or resurrect one.
        if !inherited, let index = turns?.indices.last, turns?[index].state == .running,
           timestamp > turns![index].observedAt, kind != "task_complete", kind != "turn_aborted" {
            turns?[index].observedAt = timestamp
        }
    }

    /// Hands the usage read since the last call to the ledger, keyed by its position in the rollout.
    mutating func drainUsage() -> [UsageLedger.Event] {
        defer {
            recordedUsage += usage.count
            usage = []
        }
        return usage.enumerated().map { offset, sample in
            UsageLedger.Event(key: "u\(recordedUsage + offset)", timestamp: sample.timestamp, agentId: "codex-model:\(sample.model)",
                              tokensIn: sample.input, tokensOut: sample.output, cacheReadTokens: sample.cachedInput)
        }
    }

    public func isLive(now: Date, modifiedAt: Date, freshness: TimeInterval = 120) -> Bool {
        guard turns?.last.map({ $0.state == .running }) != false, !isInternal else { return false }
        return now.timeIntervalSince(modifiedAt) < freshness && lastActivityAt != nil
    }

    public var sessionTurns: [SessionTurn] {
        guard let id, !isSubagent, !isInternal else { return [] }
        return (turns ?? []).compactMap { turn in
            guard let turnID = turn.id, !turnID.isEmpty else { return nil }
            return SessionTurn(provider: "codex", sessionID: id, turnID: turnID, state: turn.state,
                startedAtMs: turn.startedAt.map(RecordCoding.milliseconds), observedAtMs: RecordCoding.milliseconds(turn.observedAt))
        }
    }

    private mutating func finishTurn(_ id: String?, state: SessionTurn.State, at date: Date) -> Turn? {
        if let index = turns?.lastIndex(where: { $0.id == id }) {
            guard date >= turns![index].observedAt else { return nil }
            // A terminal observation is final. Repeated lines do not change its timestamp or outcome.
            guard turns![index].state == .running else { return turns![index] }
            turns?[index].state = state; turns?[index].observedAt = date
            return turns![index]
        }
        // A terminal-only log still identifies its turn, but cannot provide a start time.
        guard turns?.last?.state != .running else { return nil }
        let value = Turn(id: id, startedAt: nil, state: state, observedAt: date)
        turns = Array(((turns ?? []) + [value]).suffix(32))
        return value
    }

    private static let envelopes = ["\"session_meta\"", "\"turn_context\"", "\"event_msg\""].map { Data($0.utf8) }
}

/// Cooperative tail reader over the usage ledger. A partially written final line is retried on the next poll.
/// Each rollout is one ledger contribution; when a session's rollout exists in several places, only its newest copy counts.
public actor CodexTranscriptStore {
    private struct Entry: Codable, Sendable {
        var modifiedAt: Date
        var size: Int
        var offset: UInt64
        var transcript: CodexTranscript
    }

    /// The persisted form of an entry. A different version is read again from the rollout.
    private struct StoredEntry: Codable {
        static let version = 1
        let version: Int
        let offset: UInt64
        let transcript: CodexTranscript
    }

    public struct Session: Sendable {
        public let transcript: CodexTranscript
        public let modifiedAt: Date
        public let path: String
        public let title: String?
    }

    public struct Result: Sendable {
        public let sessions: [Session]
        public let indexing: IndexProgress?
    }

    static let source = "codex"

    let roots: [URL]
    private let indexURL: URL?
    private let ledger: UsageLedger
    private let logs: LogFiles
    private var entries: [String: Entry] = [:]
    /// Persisted entries not decoded yet, with their session ids and modification times for choosing the counted copy.
    private var stored: [String: UsageLedger.FileState] = [:]
    private var groups: [String: String] = [:]
    private var modified: [String: Date] = [:]
    private var loadedGeneration: Int?
    private var titles: (signature: String, values: [String: String]) = ("", [:])

    /// - watchesChanges: after the first listing, polls look only at rollouts a directory watch reports changed.
    public init(roots: [URL], indexURL: URL? = nil, ledger: UsageLedger = .inMemory(), watchesChanges: Bool = false) {
        self.roots = roots
        self.indexURL = indexURL
        self.ledger = ledger
        logs = LogFiles(roots: roots, watchesChanges: watchesChanges) { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
    }

    public static func standard(directory: URL = CodexLocator.dataDirectory, ledger: UsageLedger = .inMemory()) -> CodexTranscriptStore {
        CodexTranscriptStore(roots: [directory.appendingPathComponent("sessions"), directory.appendingPathComponent("archived_sessions")],
                             indexURL: directory.appendingPathComponent("session_index.jsonl"), ledger: ledger, watchesChanges: true)
    }

    /// Codex's 15-minute token totals from the period holding `since`.
    public func usage(since: Date) async -> [UsageBucket] {
        (try? await ledger.buckets(since: since, source: Self.source)) ?? []
    }

    public func index(since cutoff: Date, timeBudget: TimeInterval = 1.5) async -> Result {
        await loadIfNeeded()
        let deadline = Date().addingTimeInterval(timeBudget)
        _ = logs.refresh(now: Date())
        let candidates = logs.files.filter { $0.value.modified >= cutoff }
            .map { (url: URL(fileURLWithPath: $0.key), modified: $0.value.modified, size: $0.value.size) }
            .sorted { $0.modified > $1.modified }
        var pending = 0
        var changed: [String: (entry: Entry, events: [UsageLedger.Event], reset: Bool)] = [:]
        for candidate in candidates {
            let old = entry(candidate.url.path)
            if let old, old.size == candidate.size, old.offset == candidate.size, LedgerCopies.same(old.modifiedAt, candidate.modified) { continue }
            if Date() >= deadline { pending += 1; continue }
            guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { continue }
            defer { try? handle.close() }
            var entry = old ?? Entry(modifiedAt: candidate.modified, size: candidate.size, offset: 0, transcript: CodexTranscript())
            var reset = false
            if candidate.size < entry.offset || (old?.size == candidate.size && !LedgerCopies.same(old!.modifiedAt, candidate.modified)) {
                entry.offset = 0; entry.transcript = CodexTranscript()
                reset = old != nil
            }
            try? handle.seek(toOffset: entry.offset)
            var carry = Data()
            while Date() < deadline, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                carry.append(chunk)
                var start = carry.startIndex
                while let newline = carry[start...].firstIndex(of: 0x0A) {
                    entry.transcript.ingest(Data(carry[start..<newline]))
                    entry.offset += UInt64(newline - start + 1)
                    start = newline + 1
                }
                carry = Data(carry[start...])
            }
            entry.modifiedAt = candidate.modified; entry.size = candidate.size
            let events = entry.transcript.drainUsage()
            changed[candidate.url.path] = (entry, events, reset)
            // An incomplete final line is not an indexing backlog.
            if entry.offset + UInt64(carry.count) < candidate.size { pending += 1 }
        }
        let removed = Set(entries.keys).union(stored.keys).filter { logs.files[$0] == nil && logs.covers($0) }
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
                // Positions stay where the ledger has them, so the next poll reads the same bytes again.
                pending += changed.count
            }
        }
        let titles = readTitles()
        // A rollout can move into archived_sessions. One session id contributes usage exactly once.
        var sessions: [String: Session] = [:]
        for candidate in candidates {
            guard let entry = entry(candidate.url.path), let id = entry.transcript.id, sessions[id] == nil else { continue }
            sessions[id] = Session(transcript: entry.transcript, modifiedAt: candidate.modified, path: candidate.url.path, title: titles[id])
        }
        return Result(sessions: Array(sessions.values), indexing: pending > 0 ? IndexProgress(done: candidates.count - pending, total: candidates.count) : nil)
    }

    /// Thread names, read again only when the index file changed.
    private func readTitles() -> [String: String] {
        guard let indexURL, let values = try? indexURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [:] }
        let signature = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
        guard signature != titles.signature else { return titles.values }
        var result: [String: String] = [:]
        if let text = try? String(contentsOf: indexURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let id = item["id"] as? String, let title = item["thread_name"] as? String { result[id] = title }
            }
        }
        titles = (signature, result)
        return result
    }

    /// Reads persisted positions once, and again after a failed pass rolled the ledger back.
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
        let entry = Entry(modifiedAt: parts.modified, size: parts.size, offset: decoded.offset, transcript: decoded.transcript)
        entries[path] = entry
        return entry
    }

    private static func state(_ entry: Entry) -> UsageLedger.FileState {
        let data = try? JSONEncoder().encode(StoredEntry(version: StoredEntry.version, offset: entry.offset, transcript: entry.transcript))
        return UsageLedger.FileState(signature: LedgerCopies.signature(modified: entry.modifiedAt, size: entry.size), state: data,
                                     group: entry.transcript.id ?? "")
    }
}
