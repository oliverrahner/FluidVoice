@testable import FluidVoice_Debug
import Foundation
import XCTest

// FORK(voice-library): see FORK.md, feature "Voice library".
@MainActor
final class MeetingVoiceLibraryTests: XCTestCase {
    private func vector(_ hot: Int, noise: Float = 0) -> [Float] {
        var values = [Float](repeating: noise, count: 256)
        values[hot] = 1
        return values
    }

    private func speaker(_ name: String, _ fingerprints: [[Float]]?, merged: SessionSpeakerID? = nil, id: UUID = UUID()) -> MeetingSessionSpeaker {
        MeetingSessionSpeaker(
            id: id,
            displayName: name,
            diarizationClusterID: nil,
            trackKind: .applicationAudio,
            isLocalUser: false,
            identityCandidates: [],
            mergedIntoSpeakerID: merged,
            voiceEmbeddings: fingerprints
        )
    }

    private func session(_ speakers: [MeetingSessionSpeaker], id: UUID) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom,
                title: "Test",
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
            ),
            startedAt: Date(),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
        session.id = id
        session.speakers = speakers
        return session
    }

    private func temporaryLibrary() -> MeetingVoiceLibrary {
        MeetingVoiceLibrary(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-library-\(UUID().uuidString).json"))
    }

    func testPlaceholderNames() {
        XCTAssertTrue(MeetingVoiceMatcher.isPlaceholderName("Speaker 3"))
        XCTAssertTrue(MeetingVoiceMatcher.isPlaceholderName("You"))
        XCTAssertTrue(MeetingVoiceMatcher.isPlaceholderName("  "))
        XCTAssertFalse(MeetingVoiceMatcher.isPlaceholderName("Anna"))
        XCTAssertFalse(MeetingVoiceMatcher.isPlaceholderName("Speaker Anna"))
    }

    func testNamingASpeakerTeachesTheVoiceAndALaterMeetingUsesIt() throws {
        let library = self.temporaryLibrary()
        let speakerID = UUID()
        let meetingID = UUID()
        let before = self.session([self.speaker("Speaker 1", [self.vector(1), self.vector(1)], id: speakerID)], id: meetingID)
        var after = before
        after.speakers[0].displayName = "Anna"
        library.learn(from: before, to: after)
        XCTAssertEqual(library.people.map(\.name), ["Anna"])
        XCTAssertEqual(library.people.first?.samples.count, 2)

        let later = [
            self.speaker("Speaker 1", [self.vector(1, noise: 0.01), self.vector(1, noise: 0.02)]),
            self.speaker("Speaker 2", [self.vector(7), self.vector(7)]),
        ]
        let named = library.applyKnownNames(to: later)
        XCTAssertEqual(named.map(\.displayName), ["Anna", "Speaker 2"])
        XCTAssertEqual(named[0].identityCandidates.first?.source, MeetingVoiceMatcher.identitySource)
    }

    func testRenamingMovesTheVoiceAndPlaceholderRemovesIt() throws {
        let library = self.temporaryLibrary()
        let speakerID = UUID()
        let meetingID = UUID()
        let unnamed = self.session([self.speaker("Speaker 1", [self.vector(1), self.vector(1)], id: speakerID)], id: meetingID)
        var anna = unnamed
        anna.speakers[0].displayName = "Anna"
        library.learn(from: unnamed, to: anna)
        var berta = anna
        berta.speakers[0].displayName = "Berta"
        library.learn(from: anna, to: berta)
        XCTAssertEqual(library.people.map(\.name), ["Berta"])
        library.learn(from: berta, to: unnamed)
        XCTAssertTrue(library.people.isEmpty)
    }

    func testMergingIntoANamedSpeakerTeachesThatName() throws {
        let library = self.temporaryLibrary()
        let annaID = UUID()
        let otherID = UUID()
        let before = self.session([
            self.speaker("Anna", nil, id: annaID),
            self.speaker("Speaker 2", [self.vector(4), self.vector(4)], id: otherID),
        ], id: UUID())
        var after = before
        after.speakers[1].mergedIntoSpeakerID = annaID
        library.learn(from: before, to: after)
        XCTAssertEqual(library.people.map(\.name), ["Anna"])
    }

    func testAmbiguousOrDistantVoicesStayUnnamed() {
        let anna = MeetingVoicePerson(id: UUID(), name: "Anna", samples: [
            .init(embedding: self.vector(1), trackKind: .microphone, sessionID: UUID(), speakerID: UUID(), addedAt: Date()),
        ])
        var mixed = self.vector(1)
        mixed[2] = 1
        let berta = MeetingVoicePerson(id: UUID(), name: "Berta", samples: [
            .init(embedding: MeetingVoiceMatcher.normalized(mixed)!, trackKind: .microphone, sessionID: UUID(), speakerID: UUID(), addedAt: Date()),
        ])
        let far = UUID()
        let between = UUID()
        var halfway = self.vector(1)
        halfway[2] = 0.5
        let matches = MeetingVoiceMatcher.matches(
            speakers: [
                (far, [self.vector(9)]),
                (between, [MeetingVoiceMatcher.normalized(halfway)!]),
            ],
            people: [anna, berta]
        )
        XCTAssertNil(matches[far], "a voice far from everyone stays unnamed")
        XCTAssertNil(matches[between], "a voice equally close to two people stays unnamed")
    }

    func testOnePersonNamesOnlyTheCloserOfTwoSpeakers() {
        let anna = MeetingVoicePerson(id: UUID(), name: "Anna", samples: [
            .init(embedding: self.vector(1), trackKind: .microphone, sessionID: UUID(), speakerID: UUID(), addedAt: Date()),
        ])
        let close = UUID()
        let closer = UUID()
        let matches = MeetingVoiceMatcher.matches(
            speakers: [
                (close, [MeetingVoiceMatcher.normalized(self.vector(1, noise: 0.03))!]),
                (closer, [MeetingVoiceMatcher.normalized(self.vector(1, noise: 0.01))!]),
            ],
            people: [anna]
        )
        XCTAssertNil(matches[close])
        XCTAssertEqual(matches[closer]?.name, "Anna")
    }
}
