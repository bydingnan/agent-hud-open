import Foundation

/// Token totals of one consumer in one 15-minute period, after overlapping logs were resolved.
/// Every time zone offset is a whole number of these periods, so local quarter hours, hours and days sum them exactly.
public struct UsageBucket: Hashable, Codable, Sendable {
    public static let duration: TimeInterval = 900

    public let start: Date
    public let agentId: String
    public let tokensIn: Int
    public let tokensOut: Int
    public let cacheReadTokens: Int
    /// The provider account of usage imported from that account, the same on every machine signed into it; nil for local logs.
    public let account: String?

    public init(start: Date, agentId: String, tokensIn: Int, tokensOut: Int, cacheReadTokens: Int = 0, account: String? = nil) {
        self.start = start
        self.agentId = agentId
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheReadTokens = cacheReadTokens
        self.account = account
    }

    public var end: Date { start.addingTimeInterval(Self.duration) }
    public var total: Int { tokensIn + tokensOut }

    /// Periods are counted when they overlap the range, so a range edge inside a period includes that whole period.
    public func overlaps(_ interval: DateInterval) -> Bool { end > interval.start && start < interval.end }
}
