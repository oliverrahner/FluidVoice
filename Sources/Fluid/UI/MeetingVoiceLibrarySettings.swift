import SwiftUI

// FORK(voice-library): see FORK.md, feature "Voice library". The list of known voices in the
// FluidMeet settings. Changes apply immediately; they are not part of the settings draft.
struct MeetingVoiceLibrarySettings: View {
    @ObservedObject private var library = MeetingVoiceLibrary.shared
    @Environment(\.theme) private var theme
    @State private var confirmForgetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            FluidManagementGroup(title: "Known voices") {
                if self.library.people.isEmpty {
                    Text("No voices yet. Open a meeting, choose Assign speakers and give a speaker a name. Later meetings then name that voice automatically.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(self.library.people.enumerated()), id: \.element.id) { index, person in
                            if index > 0 { Divider() }
                            self.row(for: person)
                        }
                    }
                }
            }

            if !self.library.people.isEmpty {
                Button("Forget all voices", systemImage: "trash", role: .destructive) {
                    self.confirmForgetAll = true
                }
                .meetingGlassAction()
                .confirmationDialog(
                    "Forget all \(self.library.people.count) voices?",
                    isPresented: self.$confirmForgetAll
                ) {
                    Button("Forget all voices", role: .destructive) { self.library.forgetAll() }
                } message: {
                    Text("Meetings keep their speaker names. New meetings show numbered speakers again.")
                }
            }

            Label(
                "Voice fingerprints are stored only on this Mac (VoiceLibrary.json in FluidVoice’s Application Support folder). A wrongly named speaker can be renamed in the meeting; the voice then moves to the new name.",
                systemImage: "lock.fill"
            )
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(for person: MeetingVoicePerson) -> some View {
        HStack(spacing: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(person.name)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.detail(for: person))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Forget", systemImage: "trash") {
                self.library.forget(personID: person.id)
            }
            .labelStyle(.iconOnly)
            .help("Forget \(person.name)’s voice")
            .meetingGlassAction()
        }
        .padding(.vertical, self.theme.metrics.spacing.sm)
    }

    private func detail(for person: MeetingVoicePerson) -> String {
        let meetings = person.meetingCount == 1 ? "1 meeting" : "\(person.meetingCount) meetings"
        let sources = Set(person.samples.map(\.trackKind))
        let heard = sources.count > 1 ? "in the room and in calls"
            : sources.first == .microphone ? "on the microphone" : "in calls"
        guard let lastHeard = person.lastHeard else { return "Learned from \(meetings), \(heard)" }
        let date = lastHeard.formatted(date: .abbreviated, time: .omitted)
        return "Learned from \(meetings), \(heard) · last \(date)"
    }
}
