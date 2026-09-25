import AgentHUDSupport
import Foundation

/// Decides which completed turns and quota events are new. The island presents each update, and a host that relays
/// the same events elsewhere reads that update instead of keeping its own history, so both agree on what is new.
public struct IslandEventTracker: Sendable {
    /// A quota window that crossed a threshold, with the reading that crossed it.
    public struct Crossing: Hashable, Sendable {
        public let agent: AgentDescriptor
        public let snapshot: UsageSnapshot

        public init(agent: AgentDescriptor, snapshot: UsageSnapshot) {
            self.agent = agent
            self.snapshot = snapshot
        }
    }

    public struct Update: Sendable {
        /// Newly completed turns of clients whose Live status is on, oldest first.
        public var completions: [SessionCompletion]
        /// Turns that were in flight and stopped without finishing, of clients whose Live status is on, oldest first.
        public var interruptions: [SessionInterruption]
        /// Island quota events: warnings, exhaustion and confirmed resets.
        public var quotaAlerts: [QuotaAlert]
        /// Windows that reached zero in this update, in agent order.
        public var exhaustedWindows: [Crossing]
        /// Windows that crossed the critical threshold without also reaching zero, in agent order.
        public var criticalWindows: [Crossing]
        /// Accounts that gained usage resets in this update.
        public var resetCreditGrants: [ResetCreditGrant]

        public init(completions: [SessionCompletion] = [], interruptions: [SessionInterruption] = [],
                    quotaAlerts: [QuotaAlert] = [], exhaustedWindows: [Crossing] = [], criticalWindows: [Crossing] = [],
                    resetCreditGrants: [ResetCreditGrant] = []) {
            self.completions = completions
            self.interruptions = interruptions
            self.quotaAlerts = quotaAlerts
            self.exhaustedWindows = exhaustedWindows
            self.criticalWindows = criticalWindows
            self.resetCreditGrants = resetCreditGrants
        }
    }

    private let startedAt: Date
    private var seenCompletions: Set<String> = []
    /// The newest turn state each session reported last check, so a turn that stopped in flight can be named.
    private var turnStates: [String: SessionTurn.State] = [:]
    private var quotas = QuotaAlertTracker()
    private var resetCredits = ResetCreditTracker()

    /// Completions at or before `startedAt` are history, not events.
    public init(startedAt: Date = Date()) { self.startedAt = startedAt }

    public mutating func update(report: UsageReport, agents: [AgentDescriptor], now: Date, settings: Settings = Settings()) -> Update {
        var result = Update()
        for completion in report.completions.sorted(by: { $0.completedAt < $1.completedAt }) {
            guard completion.completedAt > startedAt, completion.completedAt <= now,
                  seenCompletions.insert(completion.id).inserted else { continue }
            // Consume suppressed events as well, so enabling live status never replays them.
            guard settings.liveStatusEnabled(for: completion.vendor) else { continue }
            result.completions.append(completion)
        }
        for interruption in stoppedTurns(report: report, agents: agents, now: now)
        where settings.liveStatusEnabled(for: interruption.vendor) {
            // Consume suppressed events as well, so enabling live status never replays them.
            result.interruptions.append(interruption)
        }
        let quota = quotas.update(report: report, agents: agents, now: now)
        result.quotaAlerts = quota.alerts
        for agent in agents {
            guard quota.exhaustedAgentIDs.contains(agent.id) || quota.criticalAgentIDs.contains(agent.id),
                  let snapshot = report.snapshot(for: agent.id) else { continue }
            // Running out supersedes the critical warning when both land in the same reading.
            if quota.exhaustedAgentIDs.contains(agent.id) {
                result.exhaustedWindows.append(Crossing(agent: agent, snapshot: snapshot))
            } else {
                result.criticalWindows.append(Crossing(agent: agent, snapshot: snapshot))
            }
        }
        result.resetCreditGrants = resetCredits.update(report: report, now: now)
        return result
    }

    /// Interruptions of the sessions whose newest turn was in flight and is now ended. The end must be as fresh as
    /// live work itself: a client that recorded the stop just now names it, while a turn a quiet source parked —
    /// Pi clients end silent turns after two minutes without moving their observation time — never reads as
    /// interrupted. A session seen for the first time establishes a baseline without reporting, and a session whose
    /// turns left the report has nothing to compare against until it returns. The vendor is resolved the way the
    /// panel resolves a session, falling back to what the turn's own source called itself.
    private mutating func stoppedTurns(report: UsageReport, agents: [AgentDescriptor], now: Date) -> [SessionInterruption] {
        var newest: [String: SessionTurn] = [:]
        for turn in report.turns where turn.observedAtMs >= (newest[turn.sessionID]?.observedAtMs ?? .min) {
            newest[turn.sessionID] = turn
        }
        var events: [SessionInterruption] = []
        for turn in newest.values.sorted(by: { $0.observedAtMs < $1.observedAtMs }) {
            if let previous = turnStates[turn.sessionID], previous == .running || previous == .waitingForApproval,
               turn.state == .ended,
               now.timeIntervalSince(RecordCoding.date(turn.observedAtMs)) < UsageRefresh.liveThreshold {
                let session = report.sessions.first { $0.id == turn.sessionID }
                let vendor = agents.first { $0.id == session?.agentId }?.vendor
                    ?? session.flatMap { SessionSource.vendor(impliedBy: $0.agentId) } ?? turn.provider
                events.append(SessionInterruption(sessionID: turn.sessionID, vendor: vendor, turnID: turn.turnID,
                    task: session?.task ?? vendor, stoppedAt: RecordCoding.date(turn.observedAtMs)))
            }
        }
        turnStates = newest.mapValues(\.state)
        return events
    }
}
