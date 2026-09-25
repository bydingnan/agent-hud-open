import AgentHUDSupport
import Foundation

/// Pi / OMP native lifecycle events are independent of persisted message usage.
/// OMP is Pi-compatible but stores under `~/.omp/agent` and may already own `extensions/agent-hud.ts`
/// for attention prompts; session turns then install as `agent-hud-session.ts`.
public enum PiSessionObserver {
    private static let filename = "agent-hud.ts"
    private static let alternateFilename = "agent-hud-session.ts"
    private static let marker = "// Agent HUD Pi session observer\n"

    /// Adapter setup is independent of the user's live-status presentation preference.
    public static func configureIfAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                            environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let paths = OpenAgentPaths(home: home, environment: environment)
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.pi.path) || manager.fileExists(atPath: paths.omp.path) else { return }
        try configure(enabled: true, home: home, environment: environment)
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let paths = OpenAgentPaths(home: home, environment: environment)
        return (try? String(contentsOf: extensionFile(in: paths.pi), encoding: .utf8)) == script
    }

    public static func configure(enabled: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let paths = OpenAgentPaths(home: home, environment: environment)
        let manager = FileManager.default
        // Explicit configure always manages the configured Pi home (tests and PI_CODING_AGENT_DIR).
        try apply(enabled: enabled, agentHome: paths.pi)
        // OMP keeps a separate agent home; install there when present and distinct.
        if manager.fileExists(atPath: paths.omp.path),
           paths.omp.resolvingSymlinksInPath() != paths.pi.resolvingSymlinksInPath() {
            try apply(enabled: enabled, agentHome: paths.omp)
        }
    }

    /// Prefer `agent-hud.ts`; if that name is already an unrelated extension (OMP attention), use the alternate.
    static func extensionFile(in agentHome: URL) -> URL {
        let primary = agentHome.appendingPathComponent("extensions/\(filename)")
        let alternate = agentHome.appendingPathComponent("extensions/\(alternateFilename)")
        if let previous = try? String(contentsOf: primary, encoding: .utf8), !previous.hasPrefix(marker) {
            return alternate
        }
        if (try? String(contentsOf: alternate, encoding: .utf8))?.hasPrefix(marker) == true {
            return alternate
        }
        return primary
    }

    private static func apply(enabled: Bool, agentHome: URL) throws {
        let file = extensionFile(in: agentHome)
        let previous = try? String(contentsOf: file, encoding: .utf8)
        // Only replace/remove our own extension, never an unrelated file with the same name.
        guard previous == nil || previous!.hasPrefix(marker) else {
            throw UsageProviderError(L10n.text("\(file.lastPathComponent) 已被其他扩展使用",
                                               "\(file.lastPathComponent) belongs to another extension"))
        }
        if enabled {
            guard previous != script else { return }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file, options: .atomic)
        } else if previous != nil {
            try FileManager.default.removeItem(at: file)
        }
    }

    struct Observation: Codable, Sendable {
        let version: Int
        let sessionID: String
        let sessionFile: String?
        let workspace: String
        let title: String
        let model: String?
        let providerID: String?
        let turnID: String
        let state: SessionTurn.State
        let startedAtMs: Int64
        let observedAtMs: Int64
        /// Product label for a Pi-compatible host. Session IDs stay `pi:` so OMP merges with its transcript.
        let host: String

        init(version: Int, sessionID: String, sessionFile: String?, workspace: String, title: String,
             model: String?, providerID: String?, turnID: String, state: SessionTurn.State,
             startedAtMs: Int64, observedAtMs: Int64, host: String = "Pi") {
            self.version = version
            self.sessionID = sessionID
            self.sessionFile = sessionFile
            self.workspace = workspace
            self.title = title
            self.model = model
            self.providerID = providerID
            self.turnID = turnID
            self.state = state
            self.startedAtMs = startedAtMs
            self.observedAtMs = observedAtMs
            self.host = host == "OMP" ? "OMP" : "Pi"
        }

        var source: OpenAgentSource { host == "OMP" ? .omp : .pi }

        var turn: SessionTurn {
            .init(provider: host, sessionID: sessionID, turnID: turnID, state: state,
                  startedAtMs: startedAtMs, observedAtMs: observedAtMs)
        }

        var session: OpenAgentSession {
            var value = OpenAgentSession(id: sessionID, client: source, title: title, workspace: workspace,
                path: sessionFile ?? "", start: RecordCoding.date(startedAtMs), end: RecordCoding.date(observedAtMs), turns: [turn])
            if let model, let providerID { value.setModel(model, provider: providerID) }
            if state == .completed {
                value.completions = [.init(sessionID: sessionID, vendor: host, turnID: turnID,
                    task: title, model: model ?? "Unknown", startedAt: RecordCoding.date(startedAtMs), completedAt: RecordCoding.date(observedAtMs))]
            }
            return value
        }
    }

    static func read(_ data: Data, path: String? = nil) throws -> Observation {
        guard data.count <= 64 * 1024 else { throw ProviderFailure.limit }
        let value = try JSONDecoder().decode(Wire.self, from: data)
        guard value.version == 1, value.sessionID.hasPrefix("pi:"), value.sessionID.count > 3,
              !value.turnID.isEmpty, value.startedAtMs > 0, value.observedAtMs >= value.startedAtMs else {
            throw ProviderFailure.format
        }
        let host = value.host == "OMP" || OpenAgentParser.isOmpAgentPath(path ?? "") ? "OMP" : "Pi"
        return Observation(version: value.version, sessionID: value.sessionID, sessionFile: value.sessionFile,
                           workspace: value.workspace, title: value.title, model: value.model, providerID: value.providerID,
                           turnID: value.turnID, state: value.state, startedAtMs: value.startedAtMs,
                           observedAtMs: value.observedAtMs, host: host)
    }

    private struct Wire: Decodable {
        let version: Int
        let sessionID: String
        let sessionFile: String?
        let workspace: String
        let title: String
        let model: String?
        let providerID: String?
        let turnID: String
        let state: SessionTurn.State
        let startedAtMs: Int64
        let observedAtMs: Int64
        let host: String?
    }

    // No Pi imports are required: this works with Pi's built-in extension loader.
    // Only lifecycle metadata leaves the process. Tokens remain owned by Pi's transcript.
    static let script = #"""
    // Agent HUD Pi session observer
    import { mkdirSync, writeFileSync, renameSync, readdirSync, statSync, unlinkSync } from "node:fs";
    import { homedir } from "node:os";
    import { dirname, join } from "node:path";
    import { createHash, randomUUID } from "node:crypto";
    import { fileURLToPath } from "node:url";

    export default function (pi) {
      // Prefer PI_CODING_AGENT_DIR; else the agent home that owns this extension file
      // (OMP installs as agent-hud-session.ts under ~/.omp/agent and often leaves PI_CODING unset).
      function agentHome() {
        if (process.env.PI_CODING_AGENT_DIR) return process.env.PI_CODING_AGENT_DIR;
        try {
          const here = fileURLToPath(import.meta.url).split("?")[0];
          const extensions = dirname(here);
          if (extensions.endsWith("/extensions") || extensions.endsWith("\\extensions")) {
            return dirname(extensions);
          }
        } catch { /* fall through */ }
        return join(homedir(), ".pi", "agent");
      }
      function hostLabel(home) {
        const norm = String(home || "").replace(/\\/g, "/");
        return /(^|\/)\.omp\/agent$/.test(norm) ? "OMP" : "Pi";
      }
      const home = agentHome();
      const host = hostLabel(home);
      const directory = join(home, "agent-hud", "turns");
      // OMP 18.x emits agent_end but not agent_settled (confirmed in omp logs). Debounce
      // agent_end like Herdr's idle path so retries/compaction can still cancel it.
      const settleDebounceMs = 750;
      let active;
      let heartbeat;
      let settleTimer;
      let lastStopReason;

      function publish(ctx, state = "running") {
        if (!active) return;
        // sessionID keeps the pi: namespace so OMP turns merge with the same transcript.
        const sessionID = "pi:" + ctx.sessionManager.getSessionId();
        const record = {
          version: 1, sessionID, sessionFile: ctx.sessionManager.getSessionFile(),
          workspace: ctx.cwd, title: ctx.sessionManager.getSessionName() || host, host,
          model: ctx.model?.id, providerID: ctx.model?.provider,
          turnID: active.id, state, startedAtMs: active.startedAtMs, observedAtMs: Date.now(),
        };
        try {
          mkdirSync(directory, { recursive: true, mode: 0o700 });
          const name = createHash("sha256").update(sessionID + "\0" + active.id).digest("hex");
          const file = join(directory, name + ".json");
          const temporary = file + "." + process.pid + ".tmp";
          writeFileSync(temporary, JSON.stringify(record), { mode: 0o600 });
          renameSync(temporary, file);
        } catch { /* Observability must never interrupt Pi's agent loop. */ }
      }

      function clearSettle() {
        if (settleTimer) clearTimeout(settleTimer);
        settleTimer = undefined;
      }

      function finish(ctx, state) {
        clearSettle();
        publish(ctx, state);
        clearInterval(heartbeat);
        heartbeat = undefined;
        active = undefined;
      }

      function terminalState() {
        const failed = lastStopReason === "error" || lastStopReason === "aborted" || lastStopReason === "length";
        return failed ? "ended" : "completed";
      }

      function scheduleFinish(ctx) {
        clearSettle();
        if (!active) return;
        settleTimer = setTimeout(() => {
          settleTimer = undefined;
          if (!active) return;
          finish(ctx, terminalState());
        }, settleDebounceMs);
        settleTimer.unref?.();
      }

      pi.on("session_start", () => {
        try {
          for (const name of readdirSync(directory)) {
            if (/^[a-f0-9]{64}\.json$/.test(name) && statSync(join(directory, name)).mtimeMs < Date.now() - 7 * 86400000) {
              unlinkSync(join(directory, name));
            }
          }
        } catch { /* The inbox is created on the first agent run. */ }
      });
      pi.on("agent_start", (_event, ctx) => {
        // Retries, auto-compaction and queued follow-ups belong to one unsettled run.
        clearSettle();
        if (!active) {
          active = { id: randomUUID(), startedAtMs: Date.now() };
          heartbeat = setInterval(() => publish(ctx), 15000);
          heartbeat.unref();
        }
        lastStopReason = undefined;
        publish(ctx);
      });
      pi.on("message_end", (event, ctx) => {
        if (event.message.role === "assistant") lastStopReason = event.message.stopReason;
        publish(ctx);
      });
      pi.on("tool_execution_start", (_event, ctx) => publish(ctx));
      pi.on("tool_execution_end", (_event, ctx) => publish(ctx));
      // OMP finishes turns with agent_end (Herdr already keys off this). agent_settled is
      // kept for Pi hosts that still emit it; only explicit failures skip the island reminder.
      pi.on("agent_end", (event, ctx) => {
        if (typeof event?.stopReason === "string") lastStopReason = event.stopReason;
        scheduleFinish(ctx);
      });
      pi.on("agent_settled", (_event, ctx) => finish(ctx, terminalState()));
      pi.on("session_shutdown", (_event, ctx) => finish(ctx, "ended"));
    }
    """#
}
