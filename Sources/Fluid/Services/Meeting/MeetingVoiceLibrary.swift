import Combine
import Foundation

// FORK(voice-library): see FORK.md, feature "Voice library".
//
// Remembers which voice belongs to which name across meetings. When a speaker is named in a
// meeting, that speaker's voice fingerprints (256-value embeddings computed locally after
// diarization) are stored under the name. Later meetings name speakers whose voice clearly
// matches one stored person. Everything stays in one local JSON file; nothing is uploaded.

nonisolated struct MeetingVoiceSample: Codable, Equatable, Sendable {
    /// Unit-length speaker embedding.
    var embedding: [Float]
    var trackKind: MeetingAudioTrackKind
    var sessionID: MeetingSessionID
    var speakerID: SessionSpeakerID
    var addedAt: Date
}

nonisolated struct MeetingVoicePerson: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var samples: [MeetingVoiceSample]

    var meetingCount: Int {
        Set(self.samples.map(\.sessionID)).count
    }

    var lastHeard: Date? {
        self.samples.map(\.addedAt).max()
    }
}

nonisolated struct MeetingVoiceMatch: Equatable, Sendable {
    let personID: UUID
    let name: String
    let distance: Float
}

nonisolated enum MeetingVoiceMatcher {
    /// Largest cosine distance between every fingerprint of a speaker and its nearest stored
    /// sample of a person that still counts as that person.
    static let maximumDistance: Float = 0.45
    /// The best person must beat the runner-up by this much, or the speaker stays unnamed.
    static let minimumMargin: Float = 0.10
    /// Newest samples kept per person.
    static let samplesPerPerson = 30
    static let identitySource = "voiceLibrary"

    static func normalized(_ embedding: [Float]) -> [Float]? {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return embedding.map { $0 / magnitude }
    }

    /// Complete-link distance: the worst of the speaker's fingerprints to its nearest sample.
    static func distance(_ fingerprints: [[Float]], to person: MeetingVoicePerson) -> Float? {
        guard !fingerprints.isEmpty else { return nil }
        var worst: Float = 0
        for fingerprint in fingerprints {
            let nearest = person.samples.compactMap {
                MeetingSpeakerEmbeddingIndex.cosineDistance(fingerprint, $0.embedding)
            }.min()
            guard let nearest, nearest.isFinite else { return nil }
            worst = max(worst, nearest)
        }
        return worst
    }

    /// People sorted by distance, nearest first.
    static func ranked(_ fingerprints: [[Float]], people: [MeetingVoicePerson]) -> [MeetingVoiceMatch] {
        people.compactMap { person in
            self.distance(fingerprints, to: person).map {
                MeetingVoiceMatch(personID: person.id, name: person.name, distance: $0)
            }
        }.sorted { $0.distance == $1.distance ? $0.name < $1.name : $0.distance < $1.distance }
    }

    /// Accepted matches, one person per speaker and one speaker per person.
    static func matches(
        speakers: [(id: SessionSpeakerID, fingerprints: [[Float]])],
        people: [MeetingVoicePerson]
    ) -> [SessionSpeakerID: MeetingVoiceMatch] {
        var accepted: [SessionSpeakerID: MeetingVoiceMatch] = [:]
        for speaker in speakers {
            let ranking = self.ranked(speaker.fingerprints, people: people)
            guard let best = ranking.first, best.distance <= self.maximumDistance else { continue }
            if ranking.count > 1, ranking[1].distance - best.distance < self.minimumMargin { continue }
            accepted[speaker.id] = best
        }
        // Two speakers claiming one person: only the closer one keeps the name.
        for group in Dictionary(grouping: accepted, by: { $0.value.personID }).values where group.count > 1 {
            let keep = group.min { $0.value.distance < $1.value.distance }?.key
            for entry in group where entry.key != keep {
                accepted[entry.key] = nil
            }
        }
        return accepted
    }

    /// Names that only number a speaker and say nothing about who it is.
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.caseInsensitiveCompare("You") == .orderedSame { return true }
        if trimmed == "Microphone / Unknown" { return true }
        return trimmed.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// A speaker's name after following merges.
    static func effectiveName(of id: SessionSpeakerID, in speakers: [MeetingSessionSpeaker]) -> String? {
        let byID = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current = byID[id]
        var hops = 0
        while let target = current?.mergedIntoSpeakerID, hops < 16 {
            current = byID[target]
            hops += 1
        }
        return current?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class MeetingVoiceLibrary: ObservableObject {
    static let shared = MeetingVoiceLibrary()

    @Published private(set) var people: [MeetingVoicePerson] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = applicationSupport
                .appendingPathComponent("FluidVoice", isDirectory: true)
                .appendingPathComponent("VoiceLibrary.json")
        }
        self.load()
    }

    /// Names placeholder speakers ("Speaker 2") whose voice clearly matches a known person.
    func applyKnownNames(to speakers: [MeetingSessionSpeaker]) -> [MeetingSessionSpeaker] {
        guard !self.people.isEmpty else { return speakers }
        let candidates = speakers.compactMap { speaker -> (id: SessionSpeakerID, fingerprints: [[Float]])? in
            guard speaker.mergedIntoSpeakerID == nil,
                  MeetingVoiceMatcher.isPlaceholderName(speaker.displayName),
                  let fingerprints = speaker.voiceEmbeddings?.compactMap(MeetingVoiceMatcher.normalized),
                  !fingerprints.isEmpty
            else { return nil }
            return (speaker.id, fingerprints)
        }
        guard !candidates.isEmpty else { return speakers }

        for candidate in candidates {
            let ranking = MeetingVoiceMatcher.ranked(candidate.fingerprints, people: self.people).prefix(2)
            let summary = ranking.map { "\($0.name) \(String(format: "%.3f", $0.distance))" }.joined(separator: ", ")
            DebugLogger.shared.info("Voice library: speaker \(candidate.id.uuidString.prefix(8)) nearest: \(summary)", source: "MeetingVoiceLibrary")
        }
        let matches = MeetingVoiceMatcher.matches(speakers: candidates, people: self.people)
        guard !matches.isEmpty else { return speakers }
        return speakers.map { speaker in
            guard let match = matches[speaker.id] else { return speaker }
            var named = speaker
            named.displayName = match.name
            named.identityCandidates.append(MeetingIdentityCandidate(
                id: UUID(),
                displayName: match.name,
                source: MeetingVoiceMatcher.identitySource,
                rejected: false,
                confirmedAt: nil
            ))
            DebugLogger.shared.info(
                "Voice library: named speaker \(speaker.id.uuidString.prefix(8)) \(match.name) (distance \(String(format: "%.3f", match.distance)))",
                source: "MeetingVoiceLibrary"
            )
            return named
        }
    }

    /// Learns from a user edit: every speaker whose effective name changed moves its
    /// fingerprints to the new name, or out of the library when the new name is a placeholder.
    func learn(from before: MeetingSession, to after: MeetingSession) {
        var people = self.people
        var changed = false
        for speaker in after.speakers {
            guard let fingerprints = speaker.voiceEmbeddings?.compactMap(MeetingVoiceMatcher.normalized),
                  !fingerprints.isEmpty
            else { continue }
            let oldName = MeetingVoiceMatcher.effectiveName(of: speaker.id, in: before.speakers)
            let newName = MeetingVoiceMatcher.effectiveName(of: speaker.id, in: after.speakers)
            guard oldName != newName else { continue }

            for index in people.indices {
                let count = people[index].samples.count
                people[index].samples.removeAll { $0.sessionID == after.id && $0.speakerID == speaker.id }
                changed = changed || people[index].samples.count != count
            }
            guard let newName, !MeetingVoiceMatcher.isPlaceholderName(newName) else { continue }

            let samples = fingerprints.map {
                MeetingVoiceSample(
                    embedding: $0,
                    trackKind: speaker.trackKind,
                    sessionID: after.id,
                    speakerID: speaker.id,
                    addedAt: Date()
                )
            }
            if let index = people.firstIndex(where: { $0.name.caseInsensitiveCompare(newName) == .orderedSame }) {
                people[index].samples += samples
                if people[index].samples.count > MeetingVoiceMatcher.samplesPerPerson {
                    people[index].samples.removeFirst(people[index].samples.count - MeetingVoiceMatcher.samplesPerPerson)
                }
            } else {
                people.append(MeetingVoicePerson(id: UUID(), name: newName, samples: samples))
            }
            changed = true
            DebugLogger.shared.info("Voice library: learned \(newName) from a meeting", source: "MeetingVoiceLibrary")
        }
        guard changed else { return }
        people.removeAll { $0.samples.isEmpty }
        self.people = people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.save()
    }

    func forget(personID: UUID) {
        self.people.removeAll { $0.id == personID }
        self.save()
    }

    func forgetAll() {
        self.people = []
        self.save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            self.people = try decoder.decode([MeetingVoicePerson].self, from: data)
        } catch {
            DebugLogger.shared.warning("Voice library unreadable: \(error.localizedDescription)", source: "MeetingVoiceLibrary")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(self.people)
            try data.write(to: self.fileURL, options: [.atomic])
        } catch {
            DebugLogger.shared.warning("Voice library not saved: \(error.localizedDescription)", source: "MeetingVoiceLibrary")
        }
    }
}
