import Foundation
import NaturalLanguage

// FORK(meeting-language): see FORK.md, features "Quick meeting language toggle" and
// "Automatic meeting language".
//
// The saved meeting language can be a concrete Parakeet v3 code ("en", "de", …) or `autoCode`.
// `autoCode` never reaches a session: `MeetingCaptureConfiguration` resolves it to a provisional
// concrete code and marks the configuration/session for language detection, so every existing
// language guard keeps operating on real language codes.
nonisolated enum MeetingLanguageChoice {
    static let autoCode = "auto"
    /// Code an automatic session carries until its transcript has been analysed.
    static let provisionalCode = "en"
    /// The default when the user never picked a meeting language.
    static let defaultCode = autoCode
    /// One-click choices shown in the record prompt and the menu bar.
    static let quickCodes = [autoCode, "en", "de"]

    static func isAuto(_ code: String?) -> Bool {
        code == self.autoCode
    }

    /// The stored preference, falling back to automatic detection when nothing was chosen.
    static func storedChoice(_ code: String?) -> String {
        guard let code, self.isValidChoice(code) else { return self.defaultCode }
        return code
    }

    static func isValidChoice(_ code: String) -> Bool {
        self.isAuto(code) || VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(code)
    }

    @MainActor
    static func displayName(for code: String) -> String {
        if self.isAuto(code) { return "Auto-detect" }
        return MeetingRetranscriptionLanguage.displayName(for: code)
    }

    /// Short label for compact segmented controls.
    @MainActor
    static func shortName(for code: String) -> String {
        switch code {
        case self.autoCode: return "Auto"
        case "en": return "English"
        case "de": return "Deutsch"
        default: return self.displayName(for: code)
        }
    }

    /// Persists a new meeting language choice without touching the rest of the saved setup.
    @MainActor
    static func save(_ code: String) {
        guard self.isValidChoice(code) else { return }
        var defaults = SettingsStore.shared.meetingRecordingDefaults
        guard defaults.languageCode != code else { return }
        defaults.languageCode = code
        SettingsStore.shared.meetingRecordingDefaults = defaults
    }

    /// Dominant language of a finished transcript, restricted to the languages the meeting model
    /// supports. Returns nil when there is too little text or no confident winner.
    static func detectLanguage(in texts: [String]) -> String? {
        var sample = ""
        for text in texts {
            sample += text
            sample += "\n"
            if sample.count >= 20000 { break }
        }
        guard sample.split(whereSeparator: \.isWhitespace).count >= 8 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.map { NLLanguage(rawValue: $0) }
        recognizer.processString(sample)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
              probability >= 0.5
        else { return nil }
        let code = language.rawValue
        return VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(code) ? code : nil
    }
}
