import Foundation

// FORK(echo-cancellation): see FORK.md, feature "Echo cancellation switch".
nonisolated enum MeetingEchoCancellationSetting {
    static let defaultsKey = "MeetingForceEchoCancellation"

    /// UserDefaults is thread-safe; the capture engine reads this from its own queues.
    static var isForced: Bool {
        UserDefaults.standard.bool(forKey: self.defaultsKey)
    }
}
