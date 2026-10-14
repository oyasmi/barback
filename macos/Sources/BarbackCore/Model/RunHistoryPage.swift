import Foundation

/// A filtered history page and the size of that same scope, before pagination.
public struct RunHistoryPage: Sendable {
    public let runs: [RunRecord]
    public let totalCount: Int
}
