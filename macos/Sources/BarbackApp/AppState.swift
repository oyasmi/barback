import Foundation
import BarbackCore
import Combine

/// Main-thread mirror of the latest `SupervisorSnapshot`, the only state SwiftUI views read.
@MainActor
public final class AppState: ObservableObject {
    @Published public var snapshot = SupervisorSnapshot(programs: [], recoveredCount: 0)
    public let supervisor: Supervisor
    public let store: Store

    public init(supervisor: Supervisor, store: Store) {
        self.supervisor = supervisor
        self.store = store
    }

    public func program(id: Int64) -> ProgramSnapshot? {
        snapshot.programs.first { $0.id == id }
    }
}
