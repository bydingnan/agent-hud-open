import XCTest
@testable import AgentHUDCore

final class PiSessionObserverTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PiObserverTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    private func observation(_ state: SessionTurn.State, age: TimeInterval = 0, turnID: String = "turn") -> PiSessionObserver.Observation {
        .init(version: 1, sessionID: "pi:session", sessionFile: nil, workspace: "/workspace", title: "Pi task",
              model: "model", providerID: "provider", turnID: turnID, state: state,
              startedAtMs: Int64(now.addingTimeInterval(-300 - age).timeIntervalSince1970 * 1000),
              observedAtMs: Int64(now.addingTimeInterval(-age).timeIntervalSince1970 * 1000))
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func report(_ local: OpenAgentLocalStore.Result, ledger: UsageLedger = .inMemory()) async throws -> UsageReport {
        let now = now
        let provider = OpenAgentUsageProvider(credentials: { [] }, sessions: { _ in local },
            fetchQuota: { _, _ in throw ProviderFailure.format }, history: QuotaHistoryStore(), clock: { now }, ledger: ledger)
        return try await provider.fetchUsage(agents: [], historyHours: 168)
    }

    func testInstallHonorsCustomHomePreservesOtherExtensionsAndIsReversible() throws {
        let home = try temporaryHome(), custom = home.appendingPathComponent("custom-agent")
        let env = ["PI_CODING_AGENT_DIR": custom.path]
        let other = custom.appendingPathComponent("extensions/other.ts")
        try write(Data("other extension".utf8), to: other)
        for _ in 0..<2 { try PiSessionObserver.configure(enabled: true, home: home, environment: env) }
        XCTAssertTrue(PiSessionObserver.isInstalled(home: home, environment: env))
        XCTAssertFalse(PiSessionObserver.isInstalled(home: home, environment: [:]))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other extension")
        try PiSessionObserver.configure(enabled: false, home: home, environment: env)
        XCTAssertFalse(PiSessionObserver.isInstalled(home: home, environment: env))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        let occupied = custom.appendingPathComponent("extensions/agent-hud.ts")
        try write(Data("unrelated".utf8), to: occupied)
        // Occupied primary name falls back to agent-hud-session.ts instead of being overwritten.
        try PiSessionObserver.configure(enabled: true, home: home, environment: env)
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "unrelated")
        let alternate = custom.appendingPathComponent("extensions/agent-hud-session.ts")
        XCTAssertEqual(try String(contentsOf: alternate, encoding: .utf8), PiSessionObserver.script)
        XCTAssertTrue(PiSessionObserver.isInstalled(home: home, environment: env))
        try PiSessionObserver.configure(enabled: false, home: home, environment: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path))
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "unrelated")
    }

    func testAutomaticSetupOnlyInstallsForAnExistingPiDirectory() throws {
        let home = try temporaryHome(), custom = home.appendingPathComponent("custom-agent")
        let env = ["PI_CODING_AGENT_DIR": custom.path]
        try PiSessionObserver.configureIfAvailable(home: home, environment: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try PiSessionObserver.configureIfAvailable(home: home, environment: env)
        XCTAssertTrue(PiSessionObserver.isInstalled(home: home, environment: env))
    }

    func testOmpAttentionExtensionKeepsAlternateSessionObserverAndHUDReadsOmpTurns() async throws {
        let home = try temporaryHome()
        let omp = home.appendingPathComponent(".omp/agent")
        let attention = omp.appendingPathComponent("extensions/agent-hud.ts")
        try write(Data("// Agent HUD Omp attention observer\nexport default function () {}\n".utf8), to: attention)
        try PiSessionObserver.configureIfAvailable(home: home, environment: [:])
        let session = omp.appendingPathComponent("extensions/agent-hud-session.ts")
        XCTAssertTrue(try String(contentsOf: attention, encoding: .utf8)
                       .hasPrefix("// Agent HUD Omp attention observer\n"))
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), PiSessionObserver.script)
        let turn = omp.appendingPathComponent("agent-hud/turns/turn.json")
        try write(JSONEncoder().encode(observation(.running)), to: turn)
        let local = await OpenAgentLocalStore(paths: OpenAgentPaths(home: home, environment: [:]))
            .index(since: now.addingTimeInterval(-86400))
        XCTAssertEqual(local.sessions.map(\.id), ["pi:session"])
        XCTAssertEqual(local.sessions.first?.client, .omp)
        XCTAssertEqual(local.sessions.first?.turns.map(\.provider), ["OMP"])
        XCTAssertEqual(local.sessions.first?.turns.map(\.state), [.running])
    }

    func testRunningBeforeFirstResponseThenUsageAndCompletionMergeIntoOneSession() async throws {
        let home = try temporaryHome(), paths = OpenAgentPaths(home: home, environment: [:])
        let observerFile = paths.piTurns.appendingPathComponent("turn.json")
        try write(JSONEncoder().encode(observation(.running)), to: observerFile)
        let store = OpenAgentLocalStore(paths: paths)
        let local = await store.index(since: now.addingTimeInterval(-86400))
        func recorded(_ ledger: UsageLedger) async throws -> [UsageBucket] { try await ledger.buckets(since: .distantPast) }
        let runningLedger = UsageLedger.inMemory(), completedLedger = UsageLedger.inMemory(), cachedLedger = UsageLedger.inMemory()
        let running = try await report(local, ledger: runningLedger)
        XCTAssertEqual(running.sessions.count, 1)
        XCTAssertTrue(try XCTUnwrap(running.sessions.first).isLive)
        XCTAssertEqual(running.consumers.first?.model, "model · provider")
        XCTAssertEqual(running.turns.first?.state, .running)
        let runningUsage = try await recorded(runningLedger)
        XCTAssertEqual(runningUsage.reduce(0) { $0 + $1.total }, 0)

        let transcript = paths.pi.appendingPathComponent("sessions/workspace/session.jsonl")
        let stamp = now.addingTimeInterval(-10).ISO8601Format()
        let usage = #"{"input":10,"output":5,"cacheRead":20,"cacheWrite":2}"#
        let message = #"{"role":"assistant","model":"model","provider":"provider","usage":\#(usage),"stopReason":"stop"}"#
        try write(Data("""
        {"type":"session","id":"session","cwd":"/workspace","timestamp":"\(now.addingTimeInterval(-600).ISO8601Format())"}
        {"type":"message","id":"response","timestamp":"\(stamp)","message":\(message)}
        """.utf8), to: transcript)
        try write(JSONEncoder().encode(observation(.completed)), to: observerFile)
        let completed = try await report(await store.index(since: now.addingTimeInterval(-86400)), ledger: completedLedger)
        XCTAssertEqual(completed.sessions.count, 1)
        let session = try XCTUnwrap(completed.sessions.first)
        XCTAssertFalse(session.isLive)
        XCTAssertEqual(session.tokensIn, 12)
        XCTAssertEqual(session.tokensOut, 5)
        XCTAssertEqual(session.cacheReadTokens, 20)
        XCTAssertEqual(session.task, "Pi task")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(session.transcriptPath)).resolvingSymlinksInPath(), transcript.resolvingSymlinksInPath())
        let completedUsage = try await recorded(completedLedger)
        XCTAssertEqual(completedUsage.reduce(0) { $0 + $1.total }, 17, "input with cache writes plus output")
        XCTAssertEqual(completed.completions.count, 1)
        XCTAssertEqual(completed.turns.first?.state, .completed)
        let cached = try await report(await store.index(since: now.addingTimeInterval(-86400)), ledger: cachedLedger)
        let cachedUsage = try await recorded(cachedLedger)
        XCTAssertEqual(cachedUsage, completedUsage)
        XCTAssertEqual(cached.turns, completed.turns, "A poll must not manufacture a newer source timestamp")
    }

    func testErrorsStaleRunsAndHistoricalCompletionDoNotFinishNewRun() async throws {
        var running = observation(.running).session
        running.turns.insert(observation(.completed, age: 600, turnID: "old").turn, at: 0)
        let active = try await report(.init(sessions: [running]))
        XCTAssertTrue(try XCTUnwrap(active.sessions.first).isLive)
        for value in [observation(.ended), observation(.running, age: 121)] {
            let result = try await report(.init(sessions: [value.session]))
            XCTAssertFalse(try XCTUnwrap(result.sessions.first).isLive)
            XCTAssertTrue(result.completions.isEmpty)
            XCTAssertEqual(result.turns.last?.state, .ended)
        }
        XCTAssertThrowsError(try PiSessionObserver.read(Data("{}".utf8)))
    }

    func testNativeExtensionLifecycleRetriesHeartbeatAndPrivacy() async throws {
        let home = try temporaryHome()
        let script = home.appendingPathComponent("observer.mjs"), test = home.appendingPathComponent("test.mjs")
        try write(Data(PiSessionObserver.script.utf8), to: script)
        try write(Data(#"""
        import assert from 'node:assert/strict';
        import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
        import { join } from 'node:path';
        import observer from './observer.mjs';
        process.env.PI_CODING_AGENT_DIR = process.argv[2];
        let timer, settle, cleared = 0, clock = 1789000000000;
        Date.now = () => ++clock;
        globalThis.setInterval = (fn, ms) => { assert.equal(ms, 15000); timer = fn; return { unref() {} }; };
        globalThis.clearInterval = () => { cleared++; timer = undefined; };
        globalThis.setTimeout = (fn, ms) => { assert.equal(ms, 750); settle = fn; return { unref() {} }; };
        globalThis.clearTimeout = () => { settle = undefined; };
        const handlers = new Map();
        const pi = { on: (name, handler) => handlers.set(name, handler) };
        const ctx = { cwd: '/workspace', model: { id: 'model', provider: 'provider' },
          sessionManager: { getSessionId: () => 'session', getSessionFile: () => undefined, getSessionName: () => 'Task' } };
        const emit = (name, event = {}) => handlers.get(name)?.(event, ctx);
        const directory = join(process.argv[2], 'agent-hud', 'turns');
        const rows = () => readdirSync(directory).filter(f => f.endsWith('.json')).map(f => JSON.parse(readFileSync(join(directory, f), 'utf8')));
        observer(pi);
        emit('session_start');
        emit('agent_start');
        const first = rows()[0];
        assert.equal(first.state, 'running');
        assert.equal(first.host, 'Pi');
        assert.equal(first.sessionFile, undefined);
        emit('message_end', { message: { role: 'assistant', stopReason: 'error', content: 'private prompt', usage: { input: 99 } } });
        emit('agent_end');
        emit('agent_start'); // retry cancels the agent_end debounce
        assert.equal(settle, undefined);
        assert.equal(rows()[0].turnID, first.turnID);
        assert.equal(rows()[0].state, 'running');
        timer();
        assert.ok(rows()[0].observedAtMs > first.observedAtMs);
        emit('message_end', { message: { role: 'assistant', stopReason: 'stop' } });
        emit('agent_end'); // OMP never emits agent_settled; debounce then completes
        assert.equal(rows()[0].state, 'running');
        settle();
        assert.equal(rows()[0].state, 'completed');
        const completedAt = rows()[0].observedAtMs;
        emit('session_shutdown');
        assert.equal(rows()[0].observedAtMs, completedAt);
        // OMP often ends after a final toolUse rather than stopReason == stop.
        emit('agent_start');
        emit('message_end', { message: { role: 'assistant', stopReason: 'toolUse' } });
        emit('agent_end'); settle();
        for (const reason of ['error', 'aborted', 'length']) {
          emit('agent_start');
          emit('message_end', { message: { role: 'assistant', stopReason: reason } });
          emit('agent_end'); settle();
        }
        emit('agent_start');
        emit('session_shutdown');
        assert.equal(rows().filter(r => r.state === 'completed').length, 2);
        assert.equal(rows().filter(r => r.state === 'ended').length, 4);
        assert.ok(cleared >= 5);
        assert.equal(JSON.stringify(rows()).includes('private prompt'), false);
        assert.equal(JSON.stringify(rows()).includes('usage'), false);
        assert.equal(JSON.stringify(rows()).includes('content'), false);
        // OMP agent homes label completions as OMP while keeping the pi: session namespace.
        const ompHome = join(process.argv[2], '.omp', 'agent');
        const ompTurns = join(ompHome, 'agent-hud', 'turns');
        process.env.PI_CODING_AGENT_DIR = ompHome;
        observer(pi);
        emit('agent_start');
        const ompRows = () => readdirSync(ompTurns).filter(f => f.endsWith('.json')).map(f => JSON.parse(readFileSync(join(ompTurns, f), 'utf8')));
        assert.equal(ompRows().at(-1).host, 'OMP');
        emit('agent_end'); settle();
        assert.equal(ompRows().at(-1).host, 'OMP');
        assert.equal(ompRows().filter(r => r.state === 'completed').at(-1).host, 'OMP');
        // Cursor-via-OMP can ask with no active turn; open one so waiting is published.
        emit('tool_execution_start', { toolName: 'ask', intent: 'Choose a target', args: null });
        const orphan = ompRows().filter(r => r.state === 'waitingForApproval');
        assert.equal(orphan.length, 1);
        assert.equal(orphan[0].message, 'Choose a target');
        emit('tool_execution_end', { toolName: 'ask' });
        // ask keeps the turn waiting even if agent_end arrives first; answering then finishes.
        emit('agent_start');
        emit('tool_execution_start', { toolName: 'ask', args: { intent: 'Pick a path', questions: [{ question: 'Ship it?' }] } });
        const waiting = ompRows().filter(r => r.state === 'waitingForApproval');
        assert.equal(waiting.length, 1);
        assert.equal(waiting[0].message, 'Pick a path');
        emit('agent_end');
        // No new settle debounce while ask is open (a prior timer reference may still linger in the mock).
        assert.equal(ompRows().filter(r => r.state === 'waitingForApproval').length, 1);
        const settleBeforeAnswer = settle;
        emit('tool_execution_end', { toolName: 'ask' });
        assert.equal(typeof settle, 'function');
        assert.notEqual(settle, settleBeforeAnswer);
        settle();
        assert.equal(ompRows().filter(r => r.state === 'waitingForApproval').length, 0);
        assert.ok(ompRows().some(r => r.state === 'completed'));
        // An unwritable inbox cannot break an agent run.
        process.env.PI_CODING_AGENT_DIR = join(process.argv[2], 'blocked');
        writeFileSync(process.env.PI_CODING_AGENT_DIR, 'file instead of directory');
        observer(pi);
        emit('agent_start'); emit('agent_settled');
        console.log('Pi native lifecycle checks passed');
        """#.utf8), to: test)
        let output = try await ProviderCommand.run("/usr/bin/env", ["node", test.path, home.path])
        XCTAssertTrue(output.contains("Pi native lifecycle checks passed"), output)
    }

    func testOmpAttentionInboxMarksAskAsWaitingAndKeepsSessionLive() async throws {
        let home = try temporaryHome()
        let paths = OpenAgentPaths(home: home, environment: [:])
        let now = now
        let attention = paths.omp.appendingPathComponent("agent-hud/attention/request.json")
        let payload: [String: Any] = [
            "sessionID": "session",
            "message": "Which approach?",
            "atMs": Int(now.timeIntervalSince1970 * 1000),
        ]
        try write(JSONSerialization.data(withJSONObject: payload), to: attention)
        try write(JSONEncoder().encode(observation(.running)), to: paths.omp.appendingPathComponent("agent-hud/turns/turn.json"))
        // Heartbeat newer than the ask must not clear a still-open attention file.
        let later = observation(.running)
        let heartbeat = PiSessionObserver.Observation(
            version: later.version, sessionID: later.sessionID, sessionFile: later.sessionFile, workspace: later.workspace,
            title: later.title, model: later.model, providerID: later.providerID, turnID: later.turnID, state: .running,
            startedAtMs: later.startedAtMs, observedAtMs: later.observedAtMs + 30_000, host: "OMP")
        try write(JSONEncoder().encode(heartbeat), to: paths.omp.appendingPathComponent("agent-hud/turns/turn.json"))
        let requests = OpenAgentAttention.read(directories: paths.attentionDirectories, now: now.addingTimeInterval(30))
        XCTAssertEqual(requests["pi:session"]?.message, "Which approach?")
        let provider = OpenAgentUsageProvider(
            credentials: { [] },
            sessions: { _ in await OpenAgentLocalStore(paths: paths).index(since: now.addingTimeInterval(-86400)) },
            attention: { OpenAgentAttention.read(directories: paths.attentionDirectories, now: now.addingTimeInterval(30)) },
            fetchQuota: { _, _ in throw ProviderFailure.format },
            history: QuotaHistoryStore(), clock: { now.addingTimeInterval(30) })
        let report = try await provider.fetchUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.turns.map(\.state), [.waitingForApproval])
        XCTAssertEqual(report.turns.first?.message, "Which approach?")
        XCTAssertTrue(try XCTUnwrap(report.sessions.first).isLive)
    }

    func testOmpAttentionReopensCompletedTurnWhileAskIsOpen() async throws {
        let home = try temporaryHome()
        let paths = OpenAgentPaths(home: home, environment: [:])
        let now = now
        let attention = paths.omp.appendingPathComponent("agent-hud/attention/request.json")
        let payload: [String: Any] = [
            "sessionID": "session",
            "message": "Pick one",
            "atMs": Int(now.timeIntervalSince1970 * 1000),
        ]
        try write(JSONSerialization.data(withJSONObject: payload), to: attention)
        // Session observer finished on agent_end while ask is still open - attention file remains.
        try write(JSONEncoder().encode(observation(.completed)), to: paths.omp.appendingPathComponent("agent-hud/turns/turn.json"))
        let provider = OpenAgentUsageProvider(
            credentials: { [] },
            sessions: { _ in await OpenAgentLocalStore(paths: paths).index(since: now.addingTimeInterval(-86400)) },
            attention: { OpenAgentAttention.read(directories: paths.attentionDirectories, now: now) },
            fetchQuota: { _, _ in throw ProviderFailure.format },
            history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.turns.map(\.state), [.waitingForApproval])
        XCTAssertEqual(report.turns.first?.message, "Pick one")
        XCTAssertTrue(report.completions.isEmpty)
        XCTAssertTrue(try XCTUnwrap(report.sessions.first).isLive)
    }

    func testClearingOmpAttentionReleasesAStaleWaitingTurn() async throws {
        let home = try temporaryHome()
        let paths = OpenAgentPaths(home: home, environment: [:])
        let now = now
        try write(Data("// Agent HUD Omp attention observer\nexport default function () {}\n".utf8),
                  to: paths.omp.appendingPathComponent("extensions/agent-hud.ts"))
        XCTAssertTrue(OpenAgentAttention.isInboxAuthoritative(in: paths))
        // Turn snapshot left waiting after the inbox file was deleted (answered / cancelled).
        let waiting = PiSessionObserver.Observation(
            version: 1, sessionID: "pi:session", sessionFile: nil, workspace: "/workspace", title: "OMP task",
            model: "model", providerID: "provider", turnID: "turn", state: .waitingForApproval,
            startedAtMs: Int64(now.addingTimeInterval(-300).timeIntervalSince1970 * 1000),
            // Older than the quiet-run expiry: release must bump observedAt or the session goes idle.
            observedAtMs: Int64(now.addingTimeInterval(-180).timeIntervalSince1970 * 1000), host: "OMP",
            message: "Still on screen?")
        try write(JSONEncoder().encode(waiting), to: paths.omp.appendingPathComponent("agent-hud/turns/turn.json"))
        let provider = OpenAgentUsageProvider(
            credentials: { [] },
            sessions: { _ in await OpenAgentLocalStore(paths: paths).index(since: now.addingTimeInterval(-86400)) },
            attention: { OpenAgentAttention.read(directories: paths.attentionDirectories, now: now) },
            attentionInboxAuthoritative: { OpenAgentAttention.isInboxAuthoritative(in: paths) },
            fetchQuota: { _, _ in throw ProviderFailure.format },
            history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.turns.map(\.state), [.running], "a cleared inbox must not leave Needs you on screen")
        XCTAssertNil(report.turns.first?.message)
        XCTAssertTrue(try XCTUnwrap(report.sessions.first).isLive,
                      "releasing a wait that sat open must keep the session live so marks and glow leave idle")
        // Pi waits without an OMP attention observer stay waiting — the turn file is the only signal.
        let piWaiting = SessionTurn(provider: "Pi", sessionID: "pi:other", turnID: "t",
                                    state: .waitingForApproval, startedAtMs: 1, observedAtMs: 2, message: "Pi ask")
        XCTAssertEqual(OpenAgentAttention.awaiting([piWaiting], requests: [:], inboxAuthoritative: true).map(\.state),
                       [.waitingForApproval])
    }

    /// A later completed snapshot must not hide a still-heartbeating earlier turn when deciding liveness.
    func testNewestInFlightObservationKeepsTheSessionLive() async throws {
        let home = try temporaryHome()
        let paths = OpenAgentPaths(home: home, environment: [:])
        let now = now
        let running = PiSessionObserver.Observation(
            version: 1, sessionID: "pi:session", sessionFile: nil, workspace: "/workspace", title: "OMP task",
            model: "model", providerID: "provider", turnID: "run", state: .running,
            startedAtMs: Int64(now.addingTimeInterval(-120).timeIntervalSince1970 * 1000),
            observedAtMs: Int64(now.timeIntervalSince1970 * 1000), host: "OMP")
        let finished = PiSessionObserver.Observation(
            version: 1, sessionID: "pi:session", sessionFile: nil, workspace: "/workspace", title: "OMP task",
            model: "model", providerID: "provider", turnID: "done", state: .completed,
            startedAtMs: Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1000),
            observedAtMs: Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1000), host: "OMP")
        try write(JSONEncoder().encode(running), to: paths.omp.appendingPathComponent("agent-hud/turns/run.json"))
        try write(JSONEncoder().encode(finished), to: paths.omp.appendingPathComponent("agent-hud/turns/done.json"))
        let provider = OpenAgentUsageProvider(
            credentials: { [] },
            sessions: { _ in await OpenAgentLocalStore(paths: paths).index(since: now.addingTimeInterval(-86400)) },
            attention: { [:] },
            fetchQuota: { _, _ in throw ProviderFailure.format },
            history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchUsage(agents: [], historyHours: 168)
        XCTAssertTrue(try XCTUnwrap(report.sessions.first).isLive,
                      "an older heartbeating turn still counts after a newer completed snapshot")
        XCTAssertEqual(report.sessions.first?.endedAt, nil)
    }
}
