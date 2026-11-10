import AudioToolbox
import Foundation

nonisolated enum MeetingAECOutputRouteDisposition: Equatable, Sendable {
    case physicallyClosed
    case supportedSpeaker
    case ambiguous
}

/// Stable output routes may attempt AEC regardless of transport. Admission still depends on real
/// PCM format/clock checks and warm-up; this classification alone never blesses processed audio.
nonisolated enum MeetingAECOutputRouteClassifier {
    static func classify(
        first: MeetingOutputRouteSnapshot,
        second: MeetingOutputRouteSnapshot,
        revisionStayedStable: Bool,
        debugDisabled: Bool = false
    ) -> MeetingAECOutputRouteDisposition {
        guard revisionStayedStable, first == second else { return .ambiguous }
        let route = second
        guard route.deviceExists else { return .ambiguous }
        // FORK(echo-cancellation): the user says the microphone hears the speakers, whatever the
        // output device reports (a headset base station feeding active speakers looks like
        // headphones). Treat every stable route as a speaker so AEC3 runs.
        if MeetingEchoCancellationSetting.isForced {
            return debugDisabled ? .ambiguous : .supportedSpeaker
        }
        // Acoustic closure is a property of the terminal, not its transport. Bluetooth alone is
        // ambiguous (it may be a room speaker), but a positively identified headphone terminal is
        // safe to admit without AEC.
        if (route.isBuiltIn && route.isHeadphonesDataSource)
            || route.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones)
        {
            return .physicallyClosed
        }
        guard !debugDisabled else { return .ambiguous }
        return .supportedSpeaker
    }
}
